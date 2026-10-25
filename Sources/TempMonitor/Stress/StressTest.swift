import Foundation

/// What the stress test needs to know about the machine at each sample.
struct StressConditions {
    var cpuTemp: Double?
    var gpuTemp: Double?
    /// The hottest of all sensors.
    var hottestTemp: Double?
    /// The fastest fan, rpm.
    var fanRPM: Double = 0
    var systemPower: Double?
    var thermalState: ProcessInfo.ThermalState = .nominal
}

/// Runs a CPU and/or GPU load and records temperatures, fans, power and throughput while it runs.
@MainActor
final class StressTest: ObservableObject {
    struct Live: Equatable {
        let start: Date
        let duration: TimeInterval
        let target: StressTarget
        var elapsed: TimeInterval = 0
        var cpuGflops: Double = 0
        var gpuGflops: Double = 0
    }

    typealias LoadFactory = (StressTarget) throws -> LoadGenerating

    static let abortTemperature = 105.0
    static let maxReports = 10
    static let durationChoices = [1, 3, 5, 10]

    @Published private(set) var live: Live?
    @Published private(set) var reports: [StressReport] = []
    @Published private(set) var lastError: String?

    private let conditions: @MainActor () -> StressConditions
    private let makeLoad: LoadFactory
    private let reportsFile: JSONFile<[StressReport]>
    private let now: () -> Date

    private var load: LoadGenerating?
    private var samples: [StressReport.Sample] = []
    private var lastCount: (flops: FlopCounts, time: Date)?
    private var worstThermal = ProcessInfo.ThermalState.nominal

    /// - Parameters:
    ///   - conditions: returns the machine's current temperatures, fans, power and thermal state.
    ///   - makeLoad: creates the load generator for a run; replaceable in tests.
    init(conditions: @escaping @MainActor () -> StressConditions,
         makeLoad: @escaping LoadFactory = { try LoadGenerator(target: $0) },
         reportsURL: URL = AppSupport.file("stress-reports.json"),
         now: @escaping () -> Date = Date.init) {
        self.conditions = conditions
        self.makeLoad = makeLoad
        self.reportsFile = JSONFile(url: reportsURL)
        self.now = now
        reports = reportsFile.load() ?? []
    }

    func start(target: StressTarget, minutes: Int) {
        guard live == nil else { return }
        do {
            let generator = try makeLoad(target)
            generator.start()
            load = generator
        } catch {
            lastError = error.localizedDescription
            return
        }
        let startTime = now()
        lastError = nil
        samples = []
        worstThermal = conditions().thermalState
        lastCount = (FlopCounts(), startTime)
        live = Live(start: startTime, duration: TimeInterval(minutes * 60), target: target)
    }

    /// Records one sample of the running test, and ends it if it's finished or unsafe. Called after each refresh.
    func sample() {
        guard var run = live, let load, let last = lastCount else { return }
        let time = now()
        let seconds = time.timeIntervalSince(last.time)
        guard seconds > 0 else { return }

        let counts = load.counts
        run.elapsed = time.timeIntervalSince(run.start)
        run.cpuGflops = (counts.cpu - last.flops.cpu) / seconds / 1e9
        run.gpuGflops = (counts.gpu - last.flops.gpu) / seconds / 1e9
        lastCount = (counts, time)
        live = run

        let state = conditions()
        if state.thermalState.rawValue > worstThermal.rawValue { worstThermal = state.thermalState }
        samples.append(.init(t: run.elapsed, cpuTemp: state.cpuTemp, gpuTemp: state.gpuTemp, fan: state.fanRPM,
                             power: state.systemPower, cpuGflops: run.cpuGflops, gpuGflops: run.gpuGflops))

        if let cause = Self.stopCause(conditions: state, elapsed: run.elapsed, duration: run.duration) {
            stop(cause)
        }
    }

    /// Why a run should end now, or nil to keep going. Safety limits take priority over completion.
    static func stopCause(conditions: StressConditions, elapsed: TimeInterval, duration: TimeInterval) -> StressStopCause? {
        if let hottest = conditions.hottestTemp, hottest >= abortTemperature { return .overheated(celsius: hottest) }
        if conditions.thermalState == .critical { return .criticalThermalState }
        if elapsed >= duration { return .completed }
        return nil
    }

    /// Ends the run and saves a report, if any samples were taken.
    func stop(_ cause: StressStopCause) {
        guard let run = live else { return }
        load?.stop()
        load = nil
        live = nil
        guard !samples.isEmpty else { return }

        let elapsed = now().timeIntervalSince(run.start)
        let report = StressReport(date: run.start, target: run.target, plannedSeconds: run.duration,
                                  seconds: min(elapsed, run.duration), endReason: cause.reportReason,
                                  worstThermalState: worstThermal.title, samples: samples)
        reports = Array(([report] + reports).prefix(Self.maxReports))
        reportsFile.save(reports)
    }

    func clearReports() {
        reports = []
        reportsFile.save(reports)
    }
}
