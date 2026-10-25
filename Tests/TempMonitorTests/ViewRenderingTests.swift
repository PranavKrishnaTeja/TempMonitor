import Foundation
import SwiftUI
import Testing
@testable import TempMonitor

/// Draws each screen off-screen to check it renders with real sensor data and with sample reports.
@MainActor
@Suite(.serialized) struct ViewRenderingTests {
    private let store = MonitorStore(history: HistoryStore(fileURL: temporaryFileURL()), stressReportsURL: temporaryFileURL())

    private func renders(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 360))
        renderer.scale = 1
        guard let image = renderer.nsImage else { return false }
        return image.size.width > 0 && image.size.height > 0
    }

    private var sampleReport: StressReport {
        let samples = (0...30).map { (i: Int) -> StressReport.Sample in
            let x = Double(i)
            return StressReport.Sample(t: x * 2, cpuTemp: 60 + x, gpuTemp: 50 + x, fan: i < 5 ? 0 : 2000,
                                       power: 30, cpuGflops: 100 - x, gpuGflops: 900)
        }
        return StressReport(date: referenceDate, target: .both, plannedSeconds: 60, seconds: 60,
                            endReason: "Stopped by you", worstThermalState: "Fair", samples: samples)
    }

    private let clock = TestClock()

    private func stressTest() -> StressTest {
        StressTest(conditions: { StressConditions(cpuTemp: 70, hottestTemp: 72) },
                   makeLoad: { _ in IdleLoad() }, reportsURL: temporaryFileURL(), now: { [clock] in clock.now })
    }

    @Test func popup() {
        store.refresh()
        #expect(renders(PopupView(store: store)))
    }

    @Test func tempsTab() {
        store.refresh()
        #expect(renders(TempsView(store: store, fahrenheit: false) { _ in }))
        #expect(renders(TempsView(store: store, fahrenheit: true) { _ in }))
    }

    @Test func systemTab() {
        store.refresh()
        store.refresh()   // power and usage need two reads
        #expect(renders(SystemView(store: store, fahrenheit: false) { _ in }))
    }

    @Test func stressTabIdleRunningAndWithReports() {
        let stress = stressTest()
        #expect(renders(StressView(stress: stress, store: store, fahrenheit: false) { _ in }))

        stress.start(target: .both, minutes: 1)
        clock.advance(2)
        stress.sample()
        #expect(renders(StressView(stress: stress, store: store, fahrenheit: false) { _ in }))

        stress.stop(.stoppedByUser)
        #expect(stress.reports.count == 1)
        #expect(renders(StressView(stress: stress, store: store, fahrenheit: false) { _ in }))
    }

    @Test(arguments: [StressTarget.cpu, .gpu, .both])
    func stressReport(target: StressTarget) {
        var report = sampleReport
        report.target = target
        #expect(renders(StressReportView(report: report, fahrenheit: true) {}))
    }

    @Test(arguments: [Metric.temperature(.cpu), .cpuUsage, .systemPower, .fan(0)])
    func detail(metric: Metric) {
        store.refresh()
        #expect(renders(DetailView(store: store, metric: metric) {}))
    }

    @Test func sharedComponents() {
        #expect(renders(StatView(title: "Peak", value: nil, detail: "12:00", tint: .red)))
        #expect(renders(BackButton {}))
        #expect(renders(SectionTitle("Fans")))
        #expect(renders(Sparkline(points: [])))
        #expect(renders(MetricRow(metric: .cpuUsage, value: nil, subtitle: nil, history: [], fahrenheit: false) {}))
        #expect(renders(Button("Row") {}.buttonStyle(HoverRowStyle())))
    }
}

private final class IdleLoad: LoadGenerating {
    var counts = FlopCounts()
    func start() {}
    func stop() {}
}
