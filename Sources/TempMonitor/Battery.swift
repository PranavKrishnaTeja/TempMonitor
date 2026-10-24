import Foundation
import IOKit

struct BatteryReading {
    var charge: Double           // 0...100
    var health: Double?          // 0...100, full-charge capacity vs design capacity
    var cycleCount: Int?
    var isCharging: Bool
    var pluggedIn: Bool
    /// Positive while charging, negative while discharging.
    var watts: Double
    var adapterWatts: Double?
    /// Minutes to empty/full; nil while macOS is still estimating.
    var minutesRemaining: Int?
}

enum BatteryReader {
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func number(_ key: String) -> NSNumber? { dict[key] as? NSNumber }

        guard let charge = number("CurrentCapacity")?.doubleValue else { return nil }
        var health: Double?
        if let raw = number("AppleRawMaxCapacity")?.doubleValue, let design = number("DesignCapacity")?.doubleValue, design > 0 {
            health = min(raw / design * 100, 100)
        }
        // Amperage is a signed value the registry stores as unsigned 64-bit; int64Value restores the sign.
        let volts = (number("Voltage")?.doubleValue ?? 0) / 1000
        let amps = Double(number("InstantAmperage")?.int64Value ?? number("Amperage")?.int64Value ?? 0) / 1000
        let remaining = number("TimeRemaining")?.intValue
        let adapter = (dict["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber

        return BatteryReading(
            charge: charge,
            health: health,
            cycleCount: number("CycleCount")?.intValue,
            isCharging: (dict["IsCharging"] as? Bool) ?? false,
            pluggedIn: (dict["ExternalConnected"] as? Bool) ?? false,
            watts: volts * amps,
            adapterWatts: adapter?.doubleValue,
            minutesRemaining: remaining.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        )
    }
}
