import Foundation

/// Keeps live samples for the last hour in memory and 1-minute aggregates for 7 days on disk.
final class HistoryStore {
    static let retention: TimeInterval = 7 * 24 * 3600
    private static let recentWindow: TimeInterval = 3600
    private static let maxChartPoints = 300
    private static let saveInterval: TimeInterval = 300

    private(set) var minutes: [HistorySample] = []
    private var recent: [HistorySample] = []
    private var bucket: MinuteBucket?
    private var lastSave: Date

    private let file: JSONFile<[HistorySample]>
    private let now: () -> Date
    private let ioQueue = DispatchQueue(label: "TempMonitor.history", qos: .utility)

    /// - Parameters:
    ///   - fileURL: where the 1-minute history is saved.
    ///   - now: the clock used for retention and save throttling; replaceable in tests.
    init(fileURL: URL = AppSupport.file("history.json"), now: @escaping () -> Date = Date.init) {
        file = JSONFile(url: fileURL)
        self.now = now
        lastSave = now()
        load()
    }

    func record(avg: [String: Double], max: [String: Double], at time: Date) {
        recent.append(HistorySample(t: time, avg: avg, max: max))
        Self.dropSamples(&recent, before: time.addingTimeInterval(-Self.recentWindow))

        if bucket?.contains(time) != true {
            flushBucket(saveIfDue: true)
            bucket = MinuteBucket(containing: time)
        }
        bucket?.add(avg: avg, max: max)
    }

    /// Flushes the partial minute and writes to disk synchronously. Call before quitting.
    func saveNow() {
        flushBucket(saveIfDue: false)
        bucket = nil
        let snapshot = minutes
        ioQueue.sync { file.save(snapshot) }
    }

    func series(key: String, range: HistoryRange, now: Date? = nil) -> [HistoryPoint] {
        let end = now ?? self.now()
        let start = end.addingTimeInterval(-range.seconds)

        // Use 1-minute history for older data and full-resolution samples for the last hour.
        let recentStart = recent.first?.t ?? end
        let samples = minutes.filter { $0.t >= start && $0.t < recentStart } + recent.filter { $0.t >= start }

        let raw = samples.compactMap { s -> Downsampler.RawPoint? in
            guard let avg = s.avg[key], let max = s.max[key] else { return nil }
            return Downsampler.RawPoint(t: s.t, avg: avg, max: max)
        }
        return Downsampler.downsample(raw, range: range, maxPoints: Self.maxChartPoints)
    }

    // MARK: - Private

    private func flushBucket(saveIfDue: Bool) {
        guard let sample = bucket?.sample else { return }
        minutes.append(sample)
        Self.dropSamples(&minutes, before: sample.t.addingTimeInterval(-Self.retention))

        let time = now()
        guard saveIfDue, time.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = time
        let snapshot = minutes
        let file = file
        ioQueue.async { file.save(snapshot) }
    }

    private func load() {
        guard let loaded = file.load() else { return }
        let cutoff = now().addingTimeInterval(-Self.retention)
        minutes = loaded.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
    }

    /// Removes leading samples older than `cutoff`. Samples are in time order.
    private static func dropSamples(_ samples: inout [HistorySample], before cutoff: Date) {
        if let i = samples.firstIndex(where: { $0.t >= cutoff }), i > 0 { samples.removeFirst(i) }
    }
}
