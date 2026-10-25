import Foundation
import IOKit

/// Anything that can read numeric SMC keys. `SMC` is the real one; tests use a dictionary.
protocol SMCKeyReading {
    /// Returns nil if the key doesn't exist.
    func read(_ key: String) -> Double?
}

/// Read-only access to the System Management Controller (fans, system power).
/// Uses the same AppleSMC user-client protocol as Stats and smcFanControl. No root required.
final class SMC: SMCKeyReading {
    // Mirrors the C SMCKeyData_t struct (80 bytes). `padding` reproduces C's tail padding after keyInfo.
    private struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct LimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0

    init?() {
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// Reads a numeric key, decoding the common SMC data types. Returns nil if the key doesn't exist.
    func read(_ key: String) -> Double? {
        guard let code = Self.fourCharCode(key) else { return nil }
        var input = KeyData()
        input.key = code
        input.data8 = Self.cmdGetKeyInfo
        guard let info = call(&input), info.result == 0 else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = Self.cmdReadKey
        guard let out = call(&input), out.result == 0 else { return nil }

        let size = Int(info.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return Self.decode(bytes, type: Self.fourCharString(info.keyInfo.dataType))
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let status = IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                               &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        return status == kIOReturnSuccess ? output : nil
    }

    // MARK: - Encoding

    /// Packs a four-character key such as "FNum" into a big-endian integer. Nil unless it's 4 bytes.
    static func fourCharCode(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func fourCharString(_ code: UInt32) -> String {
        String(bytes: withUnsafeBytes(of: code.bigEndian, Array.init), encoding: .ascii) ?? ""
    }

    /// Decodes a value of SMC data type `type` (e.g. "flt ", "sp78"). Nil for unknown or short data.
    static func decode(_ b: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where b.count >= 4:
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case "ui8 " where b.count >= 1:
            return Double(b[0])
        case "ui16" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78" where b.count >= 2:
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default:
            return nil
        }
    }
}

struct FanReading: Identifiable, Equatable {
    let index: Int
    let rpm: Double
    let min: Double
    let max: Double
    var id: Int { index }

    /// 0...1 position of the current speed between min and max.
    var fraction: Double {
        guard max > min else { return 0 }
        return Swift.min(Swift.max((rpm - min) / (max - min), 0), 1)
    }
}

enum FanReader {
    static func read(_ smc: SMCKeyReading) -> [FanReading] {
        guard let count = smc.read("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let rpm = smc.read("F\(i)Ac") else { return nil }
            return FanReading(index: i, rpm: Swift.max(rpm, 0),
                              min: smc.read("F\(i)Mn") ?? 0, max: smc.read("F\(i)Mx") ?? 0)
        }
    }
}

/// CPU and GPU core temperatures from the SMC. On Apple Silicon these are the real core sensors;
/// the HID sensors in `SensorReader` with similar names are power-management chip temperatures.
final class SMCTemperatures {
    // Known core sensor keys per chip family (as used by Stats). Only keys that exist are kept.
    static let cpuCandidates = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b", "Tp0f", "Tp0j", // M1/M2
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",                                                                 // M2
        "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",                 // M3
    ]
    static let gpuCandidates = [
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",                                                 // M1/M2
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",                                 // M3
    ]

    private let smc: SMCKeyReading
    private let keys: [(key: String, component: Component)]

    /// Nil if this Mac has none of the known core sensors.
    init?(smc: SMCKeyReading) {
        self.smc = smc
        let exists = { (key: String) in (smc.read(key) ?? 0) > 0 }
        keys = Self.cpuCandidates.filter(exists).map { ($0, .cpu) } + Self.gpuCandidates.filter(exists).map { ($0, .gpu) }
        if keys.isEmpty { return nil }
    }

    func read() -> [Reading] {
        var counts: [Component: Int] = [:]
        return keys.compactMap { key, component in
            guard let celsius = smc.read(key), Reading.isPlausible(celsius) else { return nil }
            counts[component, default: 0] += 1
            return Reading(id: "smc." + key, raw: key, name: "\(component.title) core \(counts[component]!)",
                           component: component, celsius: celsius)
        }
    }
}
