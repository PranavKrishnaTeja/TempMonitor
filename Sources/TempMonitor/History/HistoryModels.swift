import Foundation

/// Average and peak of every metric at a point in time. Keys are `Metric.key`.
struct HistorySample: Codable, Equatable {
    var t: Date
    var avg: [String: Double]
    var max: [String: Double]
}

/// One point on a chart, possibly aggregated from many samples.
struct HistoryPoint: Identifiable, Equatable {
    let t: Date
    let avg: Double
    let max: Double
    /// Increments across gaps (e.g. sleep) so the chart breaks the line instead of bridging it.
    let segment: Int
    var id: Date { t }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1H", sixHours = "6H", day = "24H", week = "7D"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        }
    }
}

/// The overall average and the highest point of a chart series.
struct SeriesStats {
    let average: Double?
    let peak: HistoryPoint?

    init(_ points: [HistoryPoint]) {
        average = points.map(\.avg).mean
        peak = points.max { $0.max < $1.max }
    }
}

/// Accumulates the samples that fall within one clock minute.
struct MinuteBucket {
    let start: Date
    private var sum: [String: Double] = [:]
    private var count: [String: Int] = [:]
    private var peak: [String: Double] = [:]

    init(containing date: Date) {
        start = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < start.addingTimeInterval(60)
    }

    mutating func add(avg: [String: Double], max: [String: Double]) {
        for (key, value) in avg {
            sum[key, default: 0] += value
            count[key, default: 0] += 1
        }
        for (key, value) in max { peak[key] = Swift.max(peak[key] ?? value, value) }
    }

    /// The minute's averages and peaks, rounded to 0.1 to keep the 7-day file small. Nil if empty.
    var sample: HistorySample? {
        guard !sum.isEmpty else { return nil }
        let avg = Dictionary(uniqueKeysWithValues: sum.map { key, total in
            (key, Self.round1(total / Double(count[key] ?? 1)))
        })
        return HistorySample(t: start, avg: avg, max: peak.mapValues(Self.round1))
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

/// Reduces a raw series to at most `maxPoints` chart points, breaking it into segments at gaps.
enum Downsampler {
    struct RawPoint: Equatable {
        let t: Date
        let avg: Double
        let max: Double
    }

    static func downsample(_ raw: [RawPoint], range: HistoryRange, maxPoints: Int) -> [HistoryPoint] {
        let width = range.seconds / Double(maxPoints)
        // A gap much wider than the sampling interval means the Mac was asleep or the app was closed.
        let gapThreshold = Swift.max(width * 3, range == .hour ? 30 : 180)

        var points: [HistoryPoint] = []
        var segment = 0
        var group: [RawPoint] = []

        func emitGroup() {
            guard let peak = group.map(\.max).max(), let avg = group.map(\.avg).mean else { return }
            points.append(HistoryPoint(t: group[group.count / 2].t, avg: avg, max: peak, segment: segment))
            group.removeAll()
        }
        func bin(_ p: RawPoint) -> Double { floor(p.t.timeIntervalSince1970 / width) }

        for point in raw {
            if let last = group.last {
                if point.t.timeIntervalSince(last.t) > gapThreshold {
                    emitGroup()
                    segment += 1
                } else if bin(point) != bin(last) {
                    emitGroup()
                }
            }
            group.append(point)
        }
        emitGroup()
        return points
    }
}
