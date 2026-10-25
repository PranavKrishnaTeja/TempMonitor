import AppKit

/// Polls every sensor on a timer, publishes the latest values and records them to history.
@MainActor
final class MonitorStore: ObservableObject {
    private static let refreshInterval: TimeInterval = 2
    /// The battery registry entry is large and changes slowly, so it's read every few refreshes.
    private static let batteryRefreshEvery = 5

    @Published private(set) var readings: [Reading] = []
    @Published private(set) var summaries: [ComponentSummary] = []
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var power: PowerReading?
    @Published private(set) var usage: UsageReading?
    @Published private(set) var memory: MemoryReading?
    @Published private(set) var battery: BatteryReading?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    /// Latest value of every metric, keyed by `Metric.key`.
    @Published private(set) var latest: [String: Double] = [:]

    let history: HistoryStore
    private(set) lazy var stress = StressTest(conditions: { [unowned self] in self.stressConditions },
                                              reportsURL: stressReportsURL)

    private let smc = SMC()
    private lazy var coreTemps = smc.flatMap(SMCTemperatures.init)
    private let powerReader = PowerReader()
    private let statsReader = SystemStatsReader()
    private let stressReportsURL: URL
    private var refreshCount = 0
    private var timer: Timer?

    init(history: HistoryStore = HistoryStore(), stressReportsURL: URL = AppSupport.file("stress-reports.json")) {
        self.history = history
        self.stressReportsURL = stressReportsURL
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
    }

    func refresh() {
        readTemperatures()
        readSystem()
        recordHistory()
        stress.sample()
    }

    func summary(for component: Component) -> ComponentSummary? {
        summaries.first { $0.component == component }
    }

    func readings(for component: Component) -> [Reading] {
        readings.filter { $0.component == component }
    }

    var fastestFanRPM: Double? { fans.map(\.rpm).max() }

    /// The last hour of a metric, for sparklines.
    func lastHour(of metric: Metric) -> [HistoryPoint] {
        history.series(key: metric.key, range: .hour)
    }

    // MARK: - Private

    private var stressConditions: StressConditions {
        StressConditions(cpuTemp: summary(for: .cpu)?.hottest,
                         gpuTemp: summary(for: .gpu)?.hottest,
                         hottestTemp: readings.map(\.celsius).max(),
                         fanRPM: fastestFanRPM ?? 0,
                         systemPower: power?.bestSystemEstimate,
                         thermalState: thermalState)
    }

    private func readTemperatures() {
        readings = SensorReader.readAll(coreReadings: coreTemps?.read() ?? [])
        summaries = ComponentSummary.summarize(readings)
    }

    private func readSystem() {
        fans = smc.map(FanReader.read) ?? []
        // Power and usage are deltas since the last read, so a failed read keeps the previous value.
        if let reading = powerReader?.read(smc: smc) { power = reading }
        if let reading = statsReader.readUsage() { usage = reading }
        memory = statsReader.readMemory()
        thermalState = ProcessInfo.processInfo.thermalState
        if refreshCount % Self.batteryRefreshEvery == 0 { battery = BatteryReader.read() }
        refreshCount += 1
    }

    private func recordHistory() {
        let snapshot = MetricSnapshot(summaries: summaries, fans: fans, power: power,
                                      usage: usage, memory: memory, battery: battery)
        latest = snapshot.peak
        history.record(avg: snapshot.average, max: snapshot.peak, at: Date())
    }

    private func shutDown() {
        stress.stop(.appQuit)
        history.saveNow()
    }
}
