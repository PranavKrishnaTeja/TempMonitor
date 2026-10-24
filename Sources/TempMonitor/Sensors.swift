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

/// The hardware part a sensor belongs to. Declaration order is display order.
enum Component: String, CaseIterable, Identifiable {
    case cpu, gpu, ssd, battery, board, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .battery: return "Battery"
        case .board: return "Power & Board"
        case .other: return "Other"
        }
    }

    /// Compact label used in the menu bar.
    var shortTitle: String {
        switch self {
        case .battery: return "BAT"
        case .board: return "PWR"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .ssd: return "internaldrive"
        case .battery: return "battery.75"
        case .board: return "bolt"
        case .other: return "thermometer"
        }
    }
}

struct Reading: Identifiable {
    let id: String          // raw sensor name, disambiguated
    let raw: String         // raw Apple sensor name
    let name: String        // friendly name
    let component: Component
    let celsius: Double
}

enum SensorReader {
    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16          // IOHIDEventFieldBase(type)

    /// Reads the HID sensors and merges in `coreReadings` from the SMC. When SMC core sensors exist,
    /// the HID die/hotspot sensors are relabeled as power-management chip temperatures.
    static func readAll(coreReadings: [Reading] = []) -> [Reading] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }

        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5,
        ]
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return []
        }

        var results: [Reading] = []
        var seen: [String: Int] = [:]

        for service in services {
            guard
                let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue(),
                let raw = nameRef as? String,
                let event = IOHIDServiceClientCopyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue()
            else { continue }

            let value = IOHIDEventGetFloatValue(event, temperatureField)
            // Filter out disconnected / garbage sensors
            guard value > 0, value < 150 else { continue }
            // Calibration references are constant and not a real part temperature.
            guard let (component, friendly) = classify(raw) else { continue }

            // Some sensors share names; disambiguate.
            let count = seen[raw, default: 0]
            seen[raw] = count + 1
            let uniqueID = count == 0 ? raw : "\(raw)#\(count)"

            if !coreReadings.isEmpty, component == .cpu || component == .gpu {
                results.append(Reading(id: uniqueID, raw: raw, name: "PMU " + friendly, component: .board, celsius: value))
            } else {
                results.append(Reading(id: uniqueID, raw: raw, name: friendly, component: component, celsius: value))
            }
        }
        results += coreReadings

        let order = Dictionary(uniqueKeysWithValues: Component.allCases.enumerated().map { ($1, $0) })
        return results.sorted {
            if $0.component != $1.component { return order[$0.component]! < order[$1.component]! }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Maps a raw Apple sensor name to a component and a readable name.
    /// Returns nil for sensors that should be hidden.
    private static func classify(_ raw: String) -> (Component, String)? {
        let lower = raw.lowercased()
        let suffix = raw.split(separator: " ").last.map(String.init) ?? raw

        if lower.contains("tcal") { return nil }
        if lower.contains("nand") || lower.contains("ssd") { return (.ssd, "SSD controller") }
        if lower.contains("battery") { return (.battery, "Battery cell") }
        if lower.contains("gpu") { return (.gpu, "GPU") }
        if lower.contains("pacc") { return (.cpu, "Performance cores") }
        if lower.contains("eacc") { return (.cpu, "Efficiency cores") }
        if lower.contains("soc") || lower.contains("ane") || lower.contains("cpu") { return (.cpu, "SoC") }

        // M1 Pro/Max style PMU names: TPng = GPU hotspot, TPns = CPU/SoC hotspot.
        if suffix.hasPrefix("TP") {
            if suffix.hasSuffix("g") { return (.gpu, "GPU hotspot \(suffix.dropFirst(2).dropLast())") }
            if suffix.hasSuffix("s") { return (.cpu, "CPU hotspot \(suffix.dropFirst(2).dropLast())") }
        }
        if lower.contains("tdie") { return (.cpu, "CPU die \(suffix.dropFirst(4))") }
        if lower.contains("tdev") { return (.board, "Power/board \(suffix.dropFirst(4))") }
        return (.other, raw)
    }
}
