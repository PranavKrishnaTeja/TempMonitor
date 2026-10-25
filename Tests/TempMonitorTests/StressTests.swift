import Foundation
import Testing
@testable import TempMonitor

private func sample(_ t: Double, cpu: Double? = nil, gpu: Double? = nil, fan: Double = 0, power: Double? = nil,
                    cpuGflops: Double = 0, gpuGflops: Double = 0) -> StressReport.Sample {
    .init(t: t, cpuTemp: cpu, gpuTemp: gpu, fan: fan, power: power, cpuGflops: cpuGflops, gpuGflops: gpuGflops)
}

private func report(_ target: StressTarget = .both, seconds: Double = 120, samples: [StressReport.Sample]) -> StressReport {
    StressReport(date: referenceDate, target: target, plannedSeconds: seconds, seconds: seconds,
                 endReason: nil, worstThermalState: "Nominal", samples: samples)
}

@Suite struct StressReportTests {
    @Test func summarizesSamples() {
        let r = report(samples: [
            sample(0, cpu: 50, gpu: 40, fan: 0, power: 10, cpuGflops: 100, gpuGflops: 1000),
            sample(2, cpu: 70, gpu: nil, fan: 2000, power: 30, cpuGflops: 200, gpuGflops: 3000),
        ])
        #expect(r.peakCPUTemp == 70)
        #expect(r.avgCPUTemp == 60)
        #expect(r.peakGPUTemp == 40)
        #expect(r.avgGPUTemp == 40)
        #expect(r.peakFan == 2000)
        #expect(r.peakPower == 30)
        #expect(r.avgPower == 20)
        #expect(r.avgCPUGflops == 150)
        #expect(r.avgGPUGflops == 2000)
    }

    @Test func emptyReport() {
        let r = report(samples: [])
        #expect(r.peakCPUTemp == nil)
        #expect(r.avgPower == nil)
        #expect(r.peakFan == 0)
        #expect(r.fanSpinUp == nil)
        #expect(r.avgCPUGflops == nil)
    }

    @Test func scoresOnlyForLoadedParts() {
        let samples = [sample(0, cpuGflops: 1, gpuGflops: 1)]
        #expect(report(.cpu, samples: samples).avgGPUGflops == nil)
        #expect(report(.cpu, samples: samples).avgCPUGflops == 1)
        #expect(report(.gpu, samples: samples).avgCPUGflops == nil)
        #expect(report(.gpu, samples: samples).avgGPUGflops == 1)
    }

    @Test func fanSpinUp() {
        #expect(report(samples: [sample(0, fan: 0), sample(2, fan: 0), sample(4, fan: 1500)]).fanSpinUp == 4)
        #expect(report(samples: [sample(0, fan: 1200), sample(2, fan: 1500)]).fanSpinUp == 0)
        #expect(report(samples: [sample(0, fan: 0), sample(2, fan: 0)]).fanSpinUp == nil)
    }

    @Test func sustainedComparesLastMinuteWithFirstThirtySeconds() {
        // Early window: t <= 30. Late window: the last 60 s of a 120 s run, t >= 60.
        let r = report(seconds: 120, samples: [
            sample(0, cpuGflops: 100), sample(30, cpuGflops: 100),
            sample(45, cpuGflops: 10),
            sample(60, cpuGflops: 80), sample(120, cpuGflops: 80),
        ])
        #expect(r.sustained(\.cpuGflops) == 80)
    }

    @Test func sustainedUsesSecondHalfOfShortRuns() {
        let r = report(seconds: 40, samples: [sample(10, cpuGflops: 100), sample(20, cpuGflops: 50), sample(30, cpuGflops: 50)])
        // Late window is the last 20 s (t >= 20); early is t <= 30, so includes all three samples.
        let early: Double = 200.0 / 3
        #expect(r.sustained(\.cpuGflops) == 50 / early * 100)
    }

    @Test func sustainedNeedsAnEarlyScore() {
        #expect(report(samples: [sample(0, cpuGflops: 0), sample(120, cpuGflops: 50)]).sustained(\.cpuGflops) == nil)
        #expect(report(samples: [sample(100, cpuGflops: 50)]).sustained(\.cpuGflops) == nil)
    }

    @Test func decodesSavedReports() throws {
        let json = """
        [{"id":"7E57D00D-0000-0000-0000-000000000000","date":1200000,"target":"CPU + GPU","plannedSeconds":60,
          "seconds":42,"endReason":"Stopped by you","worstThermalState":"Fair",
          "samples":[{"t":2,"cpuTemp":55,"fan":0,"cpuGflops":100,"gpuGflops":900}]}]
        """
        let url = temporaryFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let r = try #require(JSONFile<[StressReport]>(url: url).load()?.first)
        #expect(r.target == .both)
        #expect(r.date == referenceDate)
        #expect(r.endReason == "Stopped by you")
        #expect(r.samples == [sample(2, cpu: 55, cpuGflops: 100, gpuGflops: 900)])
    }
}

@Suite struct StressTargetTests {
    @Test func loadedParts() {
        #expect(StressTarget.cpu.loadsCPU && !StressTarget.cpu.loadsGPU)
        #expect(!StressTarget.gpu.loadsCPU && StressTarget.gpu.loadsGPU)
        #expect(StressTarget.both.loadsCPU && StressTarget.both.loadsGPU)
        #expect(StressTarget.allCases.map(\.id) == ["CPU", "GPU", "CPU + GPU"])
    }

    @Test func stopReasons() {
        #expect(StressStopCause.completed.reportReason == nil)
        #expect(StressStopCause.overheated(celsius: 105.4).reportReason == "Stopped at 105 °C (safety limit)")
        #expect(StressStopCause.criticalThermalState.reportReason == "Stopped: thermal state critical")
        #expect(StressStopCause.stoppedByUser.reportReason == "Stopped by you")
        #expect(StressStopCause.appQuit.reportReason == "App quit")
    }
}

/// A load generator that does no work; tests set its counts by hand.
private final class FakeLoad: LoadGenerating {
    var counts = FlopCounts()
    private(set) var started = false
    private(set) var stopped = false

    func start() { started = true }
    func stop() { stopped = true }
}

private struct LoadFailure: LocalizedError {
    var errorDescription: String? { "No GPU here" }
}

@MainActor
@Suite struct StressTestTests {
    private let clock = TestClock()
    private let url = temporaryFileURL()
    private var conditions = StressConditions(cpuTemp: 60, gpuTemp: 50, hottestTemp: 65, fanRPM: 1500, systemPower: 20)
    private var loads: [FakeLoad] = []

    /// Builds a test whose conditions and load can be changed through the returned boxes.
    private func makeTest(failing: Bool = false) -> (StressTest, ConditionsBox, LoadBox) {
        let box = ConditionsBox(conditions)
        let loadBox = LoadBox()
        let test = StressTest(conditions: { box.value },
                              makeLoad: { _ in
                                  if failing { throw LoadFailure() }
                                  let load = FakeLoad()
                                  loadBox.loads.append(load)
                                  return load
                              },
                              reportsURL: url,
                              now: { [clock] in clock.now })
        return (test, box, loadBox)
    }

    final class ConditionsBox {
        var value: StressConditions
        init(_ value: StressConditions) { self.value = value }
    }

    fileprivate final class LoadBox {
        var loads: [FakeLoad] = []
        var current: FakeLoad { loads.last! }
    }

    @Test func startBeginsALiveRun() {
        let (test, _, loads) = makeTest()
        test.start(target: .cpu, minutes: 3)
        #expect(test.live == StressTest.Live(start: referenceDate, duration: 180, target: .cpu))
        #expect(loads.current.started)
        #expect(test.lastError == nil)
    }

    @Test func secondStartIsIgnoredWhileRunning() {
        let (test, _, loads) = makeTest()
        test.start(target: .cpu, minutes: 1)
        test.start(target: .gpu, minutes: 5)
        #expect(test.live?.target == .cpu)
        #expect(loads.loads.count == 1)
    }

    @Test func failedStartReportsTheError() {
        let (test, _, _) = makeTest(failing: true)
        test.start(target: .gpu, minutes: 1)
        #expect(test.live == nil)
        #expect(test.lastError == "No GPU here")
    }

    @Test func samplingMeasuresThroughput() {
        let (test, _, loads) = makeTest()
        test.start(target: .both, minutes: 1)
        clock.advance(2)
        loads.current.counts = FlopCounts(cpu: 4e9, gpu: 10e9)
        test.sample()
        #expect(test.live?.elapsed == 2)
        #expect(test.live?.cpuGflops == 2)
        #expect(test.live?.gpuGflops == 5)

        clock.advance(2)
        loads.current.counts = FlopCounts(cpu: 12e9, gpu: 10e9)
        test.sample()
        #expect(test.live?.cpuGflops == 4)
        #expect(test.live?.gpuGflops == 0)
    }

    @Test func samplingWithoutElapsedTimeDoesNothing() {
        let (test, _, _) = makeTest()
        test.start(target: .cpu, minutes: 1)
        test.sample()
        #expect(test.live?.elapsed == 0)
        test.stop(.stoppedByUser)
        #expect(test.reports.isEmpty)
    }

    @Test func samplingWhenIdleDoesNothing() {
        let (test, _, _) = makeTest()
        test.sample()
        test.stop(.stoppedByUser)
        #expect(test.live == nil)
        #expect(test.reports.isEmpty)
    }

    @Test func completedRunSavesAReport() throws {
        let (test, box, loads) = makeTest()
        test.start(target: .cpu, minutes: 1)
        for _ in 0..<29 {
            clock.advance(2)
            test.sample()
        }
        #expect(test.live != nil)

        // The 30th sample, at 60 s, completes the run.
        box.value.fanRPM = 3000
        clock.advance(2)
        test.sample()

        #expect(test.live == nil)
        #expect(loads.current.stopped)
        let report = try #require(test.reports.first)
        #expect(report.endReason == nil)
        #expect(report.seconds == 60)
        #expect(report.plannedSeconds == 60)
        #expect(report.samples.count == 30)
        #expect(report.peakCPUTemp == 60)
        #expect(report.peakFan == 3000)
        #expect(report.worstThermalState == "Nominal")
    }

    @Test func stopsAtTheSafetyLimit() {
        let (test, box, _) = makeTest()
        test.start(target: .both, minutes: 10)
        box.value.hottestTemp = 106
        clock.advance(2)
        test.sample()
        #expect(test.live == nil)
        #expect(test.reports.first?.endReason == "Stopped at 106 °C (safety limit)")
        #expect(test.reports.first?.seconds == 2)
    }

    @Test func stopsAtCriticalThermalStateAndRecordsWorstState() {
        let (test, box, _) = makeTest()
        test.start(target: .both, minutes: 10)
        box.value.thermalState = .serious
        clock.advance(2)
        test.sample()
        #expect(test.live != nil)

        box.value.thermalState = .critical
        clock.advance(2)
        test.sample()
        #expect(test.live == nil)
        #expect(test.reports.first?.endReason == "Stopped: thermal state critical")
        #expect(test.reports.first?.worstThermalState == "Critical")
    }

    @Test func stopByUserKeepsSamplesSoFar() {
        let (test, _, loads) = makeTest()
        test.start(target: .gpu, minutes: 5)
        clock.advance(2)
        test.sample()
        clock.advance(1)
        test.stop(.stoppedByUser)
        #expect(loads.current.stopped)
        #expect(test.reports.first?.endReason == "Stopped by you")
        #expect(test.reports.first?.seconds == 3)
    }

    @Test func keepsOnlyTheNewestReportsAndPersistsThem() {
        let (test, _, _) = makeTest()
        for _ in 0..<(StressTest.maxReports + 2) {
            test.start(target: .cpu, minutes: 1)
            clock.advance(2)
            test.sample()
            test.stop(.stoppedByUser)
        }
        #expect(test.reports.count == StressTest.maxReports)
        #expect(test.reports.first!.date > test.reports.last!.date)

        let (reopened, _, _) = makeTest()
        #expect(reopened.reports == test.reports)
    }

    @Test func clearReportsRemovesSavedReports() {
        let (test, _, _) = makeTest()
        test.start(target: .cpu, minutes: 1)
        clock.advance(2)
        test.sample()
        test.stop(.stoppedByUser)
        test.clearReports()
        #expect(test.reports.isEmpty)
        #expect(makeTest().0.reports.isEmpty)
    }

    @Test func stopCausePriorities() {
        let hot = StressConditions(hottestTemp: 105, thermalState: .critical)
        #expect(StressTest.stopCause(conditions: hot, elapsed: 100, duration: 60) == .overheated(celsius: 105))
        let critical = StressConditions(hottestTemp: 90, thermalState: .critical)
        #expect(StressTest.stopCause(conditions: critical, elapsed: 100, duration: 60) == .criticalThermalState)
        let fine = StressConditions(hottestTemp: 90)
        #expect(StressTest.stopCause(conditions: fine, elapsed: 60, duration: 60) == .completed)
        #expect(StressTest.stopCause(conditions: fine, elapsed: 59, duration: 60) == nil)
        #expect(StressTest.stopCause(conditions: StressConditions(), elapsed: 0, duration: 60) == nil)
    }
}
