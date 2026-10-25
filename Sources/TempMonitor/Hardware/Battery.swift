import Foundation
import IOKit

struct BatteryReading: Equatable {
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

    /// macOS reports 65535 minutes while it's still estimating.
    private static let unknownTimeRemaining = 65535

    /// Parses the `AppleSmartBattery` registry properties. Nil if there's no charge level.
    init?(properties dict: [String: Any]) {
        func number(_ key: String) -> NSNumber? { dict[key] as? NSNumber }

        guard let charge = number("CurrentCapacity")?.doubleValue else { return nil }
        self.charge = charge
        if let raw = number("AppleRawMaxCapacity")?.doubleValue, let design = number("DesignCapacity")?.doubleValue, design > 0 {
            health = min(raw / design * 100, 100)
        }
        cycleCount = number("CycleCount")?.intValue
        isCharging = (dict["IsCharging"] as? Bool) ?? false
        pluggedIn = (dict["ExternalConnected"] as? Bool) ?? false

        // Amperage is a signed value the registry stores as unsigned 64-bit; int64Value restores the sign.
        let volts = (number("Voltage")?.doubleValue ?? 0) / 1000
        let amps = Double(number("InstantAmperage")?.int64Value ?? number("Amperage")?.int64Value ?? 0) / 1000
        watts = volts * amps

        adapterWatts = ((dict["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber)?.doubleValue
        let remaining = number("TimeRemaining")?.intValue
        minutesRemaining = remaining.flatMap { 0 < $0 && $0 < Self.unknownTimeRemaining ? $0 : nil }
    }

    /// e.g. "Charging · 1h 5m to full" or "On battery".
    var statusText: String {
        let state = isCharging ? "Charging" : pluggedIn ? "Plugged in" : "On battery"
        guard let minutes = minutesRemaining else { return state }
        return "\(state) · \(minutes / 60)h \(minutes % 60)m \(isCharging ? "to full" : "left")"
    }

    var flowText: String { watts >= 0 ? "Into battery" : "Out of battery" }
}

enum BatteryReader {
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryReading(properties: dict)
    }
}
