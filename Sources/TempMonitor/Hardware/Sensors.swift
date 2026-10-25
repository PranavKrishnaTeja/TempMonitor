import Foundation
import IOKit

// Private IOKit HID symbols used to read Apple Silicon thermal sensors.
// No root or entitlements required.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// A temperature as reported by one HID sensor, before classification.
struct RawSensorValue: Equatable {
    let name: String
    let celsius: Double
}

enum SensorReader {
    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16          // IOHIDEventFieldBase(type)

    /// Reads the HID sensors and merges in `coreReadings` from the SMC.
    static func readAll(coreReadings: [Reading] = []) -> [Reading] {
        assemble(readHIDSensors(), coreReadings: coreReadings)
    }

    /// Turns raw HID values into sorted, named readings. Implausible and hidden sensors are dropped and
    /// duplicate names get a "#n" suffix. When SMC core sensors exist, the HID CPU/GPU sensors are
    /// relabeled as power-management chip (PMU) temperatures, since they aren't the cores themselves.
    static func assemble(_ values: [RawSensorValue], coreReadings: [Reading]) -> [Reading] {
        var results: [Reading] = []
        var seen: [String: Int] = [:]

        for value in values where Reading.isPlausible(value.celsius) {
            guard let kind = SensorClassifier.classify(value.name) else { continue }

            let count = seen[value.name, default: 0]
            seen[value.name] = count + 1
            let id = count == 0 ? value.name : "\(value.name)#\(count)"

            let isPMU = !coreReadings.isEmpty && (kind.component == .cpu || kind.component == .gpu)
            results.append(Reading(id: id, raw: value.name,
                                   name: isPMU ? "PMU " + kind.name : kind.name,
                                   component: isPMU ? .board : kind.component,
                                   celsius: value.celsius))
        }
        return (results + coreReadings).sorted(by: Reading.displayOrder)
    }

    private static func readHIDSensors() -> [RawSensorValue] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5,
        ]
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return []
        }
        return services.compactMap { service in
            guard
                let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                let event = IOHIDServiceClientCopyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue()
            else { return nil }
            return RawSensorValue(name: name, celsius: IOHIDEventGetFloatValue(event, temperatureField))
        }
    }
}

/// Maps raw Apple sensor names to a component and a readable name.
enum SensorClassifier {
    struct Kind: Equatable {
        let component: Component
        let name: String
    }

    /// Returns nil for sensors that should be hidden, such as constant calibration references.
    static func classify(_ raw: String) -> Kind? {
        let lower = raw.lowercased()
        let suffix = raw.split(separator: " ").last.map(String.init) ?? raw

        if lower.contains("tcal") { return nil }
        if lower.contains("nand") || lower.contains("ssd") { return Kind(component: .ssd, name: "SSD controller") }
        if lower.contains("battery") { return Kind(component: .battery, name: "Battery cell") }
        if lower.contains("gpu") { return Kind(component: .gpu, name: "GPU") }
        if lower.contains("pacc") { return Kind(component: .cpu, name: "Performance cores") }
        if lower.contains("eacc") { return Kind(component: .cpu, name: "Efficiency cores") }
        if lower.contains("soc") || lower.contains("ane") || lower.contains("cpu") { return Kind(component: .cpu, name: "SoC") }

        // M1 Pro/Max style PMU names: TPng = GPU hotspot, TPns = CPU/SoC hotspot.
        if suffix.hasPrefix("TP") {
            let number = suffix.dropFirst(2).dropLast()
            if suffix.hasSuffix("g") { return Kind(component: .gpu, name: "GPU hotspot \(number)") }
            if suffix.hasSuffix("s") { return Kind(component: .cpu, name: "CPU hotspot \(number)") }
        }
        if lower.contains("tdie") { return Kind(component: .cpu, name: "CPU die \(suffix.dropFirst(4))") }
        if lower.contains("tdev") { return Kind(component: .board, name: "Power/board \(suffix.dropFirst(4))") }
        return Kind(component: .other, name: raw)
    }
}
