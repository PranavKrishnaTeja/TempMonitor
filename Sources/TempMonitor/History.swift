import Foundation

/// Average and peak of every metric at a point in time. Keys are `Metric.key`.
struct HistorySample: Codable {
    var t: Date
    var avg: [String: Double]
    var max: [String: Double]
}

/// One point on a chart, possibly aggregated from many samples.
struct HistoryPoint: Identifiable {
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

/// Keeps live 2s samples for the last hour in memory and 1-minute aggregates for 7 days on disk.
final class HistoryStore {
    static let retention: TimeInterval = 7 * 24 * 3600
    private static let recentWindow: TimeInterval = 3600
    private static let maxChartPoints = 300
    private static let saveInterval: TimeInterval = 300

    private(set) var minutes: [HistorySample] = []
    private var recent: [HistorySample] = []
    private var bucket: (start: Date, sum: [String: Double], count: [String: Int], max: [String: Double])?
    private var lastSave = Date()

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "TempMonitor.history", qos: .utility)

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TempMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func record(avg: [String: Double], max: [String: Double], at now: Date) {
        let sample = HistorySample(t: now, avg: avg, max: max)
        recent.append(sample)
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        if let i = recent.firstIndex(where: { $0.t >= cutoff }), i > 0 { recent.removeFirst(i) }

        let minuteStart = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        if bucket?.start != minuteStart {
            flushBucket()
            bucket = (minuteStart, [:], [:], [:])
        }
        for (k, v) in avg {
            bucket!.sum[k, default: 0] += v
            bucket!.count[k, default: 0] += 1
        }
        for (k, v) in max { bucket!.max[k] = Swift.max(bucket!.max[k] ?? v, v) }
    }

    /// Flushes the partial minute and writes to disk synchronously. Call before quitting.
    func saveNow() {
        flushBucket(save: false)
        bucket = nil
        let snapshot = minutes
        ioQueue.sync { Self.write(snapshot, to: fileURL) }
    }

    func series(key: String, range: HistoryRange, now: Date = Date()) -> [HistoryPoint] {
        let start = now.addingTimeInterval(-range.seconds)

        // Use 1-minute history for older data and full-resolution samples for the last hour.
        let recentStart = recent.first?.t ?? now
        var samples = minutes.filter { $0.t >= start && $0.t < recentStart }
        samples += recent.filter { $0.t >= start }

        let raw = samples.compactMap { s -> (Date, Double, Double)? in
            guard let a = s.avg[key], let m = s.max[key] else { return nil }
            return (s.t, a, m)
        }
        return downsample(raw, range: range)
    }

    // MARK: - Private

    private func downsample(_ raw: [(Date, Double, Double)], range: HistoryRange) -> [HistoryPoint] {
        guard !raw.isEmpty else { return [] }
        let width = range.seconds / Double(Self.maxChartPoints)
        // A gap much wider than the sampling interval means the Mac was asleep or the app was closed.
        let gapThreshold = Swift.max(width * 3, range == .hour ? 30 : 180)

        var points: [HistoryPoint] = []
        var segment = 0
        var group: [(Date, Double, Double)] = []
        var groupKey = -1.0
        var lastT: Date?

        func emit() {
            guard !group.isEmpty else { return }
            let avg = group.map(\.1).reduce(0, +) / Double(group.count)
            let peak = group.map(\.2).max()!
            points.append(HistoryPoint(t: group[group.count / 2].0, avg: avg, max: peak, segment: segment))
            group.removeAll()
        }

        for item in raw {
            let k = floor(item.0.timeIntervalSince1970 / width)
            if let last = lastT, item.0.timeIntervalSince(last) > gapThreshold {
                emit()
                segment += 1
            } else if k != groupKey {
                emit()
            }
            groupKey = k
            group.append(item)
            lastT = item.0
        }
        emit()
        return points
    }

    private func bucketSample() -> HistorySample? {
        guard let b = bucket, !b.sum.isEmpty else { return nil }
        // Rounded to 0.1 to keep the 7-day file small.
        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        let avg = Dictionary(uniqueKeysWithValues: b.sum.map { k, sum in (k, round1(sum / Double(b.count[k] ?? 1))) })
        return HistorySample(t: b.start, avg: avg, max: b.max.mapValues(round1))
    }

    private func flushBucket(save: Bool = true) {
        guard let sample = bucketSample() else { return }
        minutes.append(sample)
        let cutoff = sample.t.addingTimeInterval(-Self.retention)
        if let i = minutes.firstIndex(where: { $0.t >= cutoff }), i > 0 { minutes.removeFirst(i) }
        if save, Date().timeIntervalSince(lastSave) >= Self.saveInterval {
            lastSave = Date()
            let snapshot = minutes
            let url = fileURL
            ioQueue.async { Self.write(snapshot, to: url) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let loaded = try? decoder.decode([HistorySample].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        minutes = loaded.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
    }

    private static func write(_ samples: [HistorySample], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
