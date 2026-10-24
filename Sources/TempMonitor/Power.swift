import Foundation

// Private libIOReport symbols (same approach as macmon). No root required.
@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?

@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ channels: CFMutableDictionary,
                                        _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                        _ d: UInt64, _ e: CFTypeRef?) -> Unmanaged<AnyObject>?

@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ subscription: AnyObject, _ channels: CFMutableDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ previous: CFDictionary, _ current: CFDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ channel: CFDictionary, _ a: Int32) -> Int64

struct PowerReading {
    var cpu: Double = 0
    var gpu: Double = 0
    var ane: Double = 0
    var dram: Double = 0
    /// Whole-machine draw from the SMC, if available.
    var system: Double?
}

/// Computes component power from IOReport "Energy Model" energy counters between successive calls.
final class PowerReader {
    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var previous: (samples: CFDictionary, time: Date)?

    init?() {
        guard let group = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, group, &subscribed, 0, nil)?.takeRetainedValue(),
              let channels = subscribed?.takeRetainedValue() else { return nil }
        subscription = sub
        self.channels = channels
        _ = read(smc: nil)
    }

    /// Returns average watts since the previous call (nil on the first call).
    func read(smc: SMC?) -> PowerReading? {
        guard let current = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { previous = (current, now) }
        guard let prev = previous,
              let delta = IOReportCreateSamplesDelta(prev.samples, current, nil)?.takeRetainedValue() else { return nil }
        let seconds = now.timeIntervalSince(prev.time)
        guard seconds > 0, let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }

        var reading = PowerReading()
        for channel in items {
            guard let name = IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String? else { continue }
            let unit = IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as String? ?? "mJ"
            let joules = Double(IOReportSimpleGetIntegerValue(channel, 0)) / Self.divisor(for: unit)
            let watts = joules / seconds

            // M2+ report "CPU Energy"/"GPU Energy"; M1-family report per-cluster totals
            // ("EACC_CPU", "PACC0_CPU") and "GPU0". Per-core channels ("PACC0_CPU0") are skipped.
            if name == "GPU Energy" || name.wholeMatch(of: #/GPU\d*/#) != nil { reading.gpu += watts }
            else if name.hasSuffix("CPU Energy") || name.wholeMatch(of: #/[EP]ACC\d*_CPU/#) != nil { reading.cpu += watts }
            else if name.hasPrefix("ANE") { reading.ane += watts }
            else if name.hasPrefix("DRAM") { reading.dram += watts }
        }
        if let pstr = smc?.read("PSTR"), pstr > 0 { reading.system = pstr }
        return reading
    }

    private static func divisor(for unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "nJ": return 1e9
        case "uJ", "µJ": return 1e6
        default: return 1e3
        }
    }
}
