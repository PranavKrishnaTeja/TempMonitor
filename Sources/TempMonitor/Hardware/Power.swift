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

struct PowerReading: Equatable {
    var cpu: Double = 0
    var gpu: Double = 0
    var ane: Double = 0
    var dram: Double = 0
    /// Whole-machine draw from the SMC, if available.
    var system: Double?

    /// The whole-machine draw, or CPU + GPU when the SMC doesn't report it.
    var bestSystemEstimate: Double { system ?? cpu + gpu }

    /// Adds an IOReport energy channel's average watts to the component it belongs to.
    /// M2+ report "CPU Energy"/"GPU Energy"; M1-family report per-cluster totals
    /// ("EACC_CPU", "PACC0_CPU") and "GPU0". Per-core channels ("PACC0_CPU0") are ignored.
    mutating func add(channel name: String, watts: Double) {
        if name == "GPU Energy" || name.wholeMatch(of: #/GPU\d*/#) != nil { gpu += watts }
        else if name.hasSuffix("CPU Energy") || name.wholeMatch(of: #/[EP]ACC\d*_CPU/#) != nil { cpu += watts }
        else if name.hasPrefix("ANE") { ane += watts }
        else if name.hasPrefix("DRAM") { dram += watts }
    }
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
    func read(smc: SMCKeyReading?) -> PowerReading? {
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
            let joules = Self.joules(IOReportSimpleGetIntegerValue(channel, 0), unit: unit)
            reading.add(channel: name, watts: joules / seconds)
        }
        if let pstr = smc?.read("PSTR"), pstr > 0 { reading.system = pstr }
        return reading
    }

    /// Converts an energy counter in `unit` ("nJ", "uJ", "mJ"; unknown units are treated as mJ) to joules.
    static func joules(_ value: Int64, unit: String) -> Double {
        let perJoule: Double
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "nJ": perJoule = 1e9
        case "uJ", "µJ": perJoule = 1e6
        default: perJoule = 1e3
        }
        return Double(value) / perJoule
    }
}
