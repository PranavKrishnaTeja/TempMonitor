import Foundation

/// The results of one stress run, as saved to disk.
struct StressReport: Codable, Identifiable, Hashable {
    struct Sample: Codable, Hashable {
        var t: Double                // seconds since start
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fan: Double              // fastest fan, rpm
        var power: Double?           // system watts
        var cpuGflops: Double
        var gpuGflops: Double
    }

    /// Scores are compared between the first `earlyWindow` seconds and up to the last `lateWindow` seconds.
    static let earlyWindow: Double = 30
    static let lateWindow: Double = 60

    var id = UUID()
    var date: Date
    var target: StressTarget
    var plannedSeconds: Double
    var seconds: Double
    /// nil when the run completed; otherwise why it stopped early.
    var endReason: String?
    var worstThermalState: String
    var samples: [Sample]

    var peakCPUTemp: Double? { samples.compactMap(\.cpuTemp).max() }
    var avgCPUTemp: Double? { samples.compactMap(\.cpuTemp).mean }
    var peakGPUTemp: Double? { samples.compactMap(\.gpuTemp).max() }
    var avgGPUTemp: Double? { samples.compactMap(\.gpuTemp).mean }
    var peakFan: Double { samples.map(\.fan).max() ?? 0 }
    var peakPower: Double? { samples.compactMap(\.power).max() }
    var avgPower: Double? { samples.compactMap(\.power).mean }
    var avgCPUGflops: Double? { target.loadsCPU ? samples.map(\.cpuGflops).mean : nil }
    var avgGPUGflops: Double? { target.loadsGPU ? samples.map(\.gpuGflops).mean : nil }

    /// Seconds until the fans started, nil if they never ran. Zero means they were already running.
    var fanSpinUp: Double? {
        guard let first = samples.first else { return nil }
        if first.fan > 0 { return 0 }
        return samples.first { $0.fan > 0 }?.t
    }

    /// Late-run score as a percentage of the early-run score. Well below 100% suggests thermal throttling.
    func sustained(_ score: KeyPath<Sample, Double>) -> Double? {
        let lateStart = seconds - min(Self.lateWindow, seconds / 2)
        guard let early = samples.filter({ $0.t <= Self.earlyWindow }).map({ $0[keyPath: score] }).mean, early > 0,
              let late = samples.filter({ $0.t >= lateStart }).map({ $0[keyPath: score] }).mean
        else { return nil }
        return late / early * 100
    }
}

/// Which part of the chip a stress run loads.
enum StressTarget: String, Codable, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", both = "CPU + GPU"

    var id: String { rawValue }
    var loadsCPU: Bool { self != .gpu }
    var loadsGPU: Bool { self != .cpu }
}

/// Why a stress run ended.
enum StressStopCause: Equatable {
    case completed
    case overheated(celsius: Double)
    case criticalThermalState
    case stoppedByUser
    case appQuit

    /// The text saved in the report; nil for a run that completed normally.
    var reportReason: String? {
        switch self {
        case .completed: return nil
        case .overheated(let celsius): return String(format: "Stopped at %.0f °C (safety limit)", celsius)
        case .criticalThermalState: return "Stopped: thermal state critical"
        case .stoppedByUser: return "Stopped by you"
        case .appQuit: return "App quit"
        }
    }
}
