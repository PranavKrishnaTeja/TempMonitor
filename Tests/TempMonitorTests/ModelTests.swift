import Foundation
import SwiftUI
import Testing
@testable import TempMonitor

@Suite struct ComponentTests {
    @Test func sortsInDeclarationOrder() {
        #expect([Component.other, .cpu, .board, .gpu].sorted() == [.cpu, .gpu, .board, .other])
    }

    @Test func shortTitlesAreCompact() {
        #expect(Component.battery.shortTitle == "BAT")
        #expect(Component.board.shortTitle == "PWR")
        #expect(Component.cpu.shortTitle == "CPU")
    }

    @Test func everyComponentHasTitleAndSymbol() {
        for component in Component.allCases {
            #expect(!component.title.isEmpty)
            #expect(!component.symbol.isEmpty)
            #expect(component.id == component.rawValue)
        }
    }
}

@Suite struct ReadingTests {
    @Test(arguments: [(-5.0, false), (0.0, false), (0.1, true), (149.9, true), (150.0, false)])
    func plausibleRange(celsius: Double, plausible: Bool) {
        #expect(Reading.isPlausible(celsius) == plausible)
    }

    @Test func displayOrderSortsByComponentThenNaturalName() {
        let sorted = [reading("Core 10", .cpu, 1), reading("SSD", .ssd, 1), reading("Core 2", .cpu, 1), reading("GPU", .gpu, 1)]
            .sorted(by: Reading.displayOrder)
        #expect(sorted.map(\.name) == ["Core 2", "Core 10", "GPU", "SSD"])
    }
}

@Suite struct ComponentSummaryTests {
    @Test func summarizesEachComponentInDisplayOrder() {
        let summaries = ComponentSummary.summarize([
            reading("a", .gpu, 50), reading("b", .cpu, 40), reading("c", .cpu, 60), reading("d", .cpu, 50),
        ])
        #expect(summaries == [
            ComponentSummary(component: .cpu, hottest: 60, average: 50, sensorCount: 3),
            ComponentSummary(component: .gpu, hottest: 50, average: 50, sensorCount: 1),
        ])
    }

    @Test func noReadingsMeansNoSummaries() {
        #expect(ComponentSummary.summarize([]).isEmpty)
    }
}

@Suite struct MenuBarModeTests {
    let summaries = ComponentSummary.summarize([
        reading("cpu", .cpu, 58.4), reading("gpu", .gpu, 56), reading("ssd", .ssd, 70),
    ])

    @Test func cpuAndGPU() {
        #expect(MenuBarMode.cpuGpu.text(for: summaries, fahrenheit: false) == "CPU 58°  GPU 56°")
    }

    @Test func cpuOnly() {
        #expect(MenuBarMode.cpu.text(for: summaries, fahrenheit: false) == "CPU 58°")
    }

    @Test func hottestPart() {
        #expect(MenuBarMode.hottest.text(for: summaries, fahrenheit: false) == "SSD 70°")
    }

    @Test func fahrenheit() {
        #expect(MenuBarMode.cpu.text(for: summaries, fahrenheit: true) == "CPU 137°")
    }

    @Test(arguments: MenuBarMode.allCases)
    func placeholderWithoutSensors(mode: MenuBarMode) {
        #expect(mode.text(for: [], fahrenheit: false) == "--")
        #expect(!mode.title.isEmpty)
    }

    @Test func cpuGpuShowsWhicheverExists() {
        let gpuOnly = ComponentSummary.summarize([reading("gpu", .gpu, 41)])
        #expect(MenuBarMode.cpuGpu.text(for: gpuOnly, fahrenheit: false) == "GPU 41°")
    }
}

@Suite struct MetricUnitTests {
    @Test func formatsEachUnit() {
        #expect(MetricUnit.temperature.format(58, fahrenheit: false) == "58°C")
        #expect(MetricUnit.rpm.format(0.5) == "Off")
        #expect(MetricUnit.rpm.format(1234.4) == "1234 rpm")
        #expect(MetricUnit.watts.format(5.27) == "5.3 W")
        #expect(MetricUnit.watts.format(-3.46) == "-3.5 W")
        #expect(MetricUnit.watts.format(12.4) == "12 W")
        #expect(MetricUnit.percent.format(42.4) == "42%")
        #expect(MetricUnit.gigabytes.format(8.26) == "8.3 GB")
    }

    @Test func onlyTemperatureChangesForDisplay() {
        #expect(MetricUnit.temperature.display(100, fahrenheit: true) == 212)
        #expect(MetricUnit.watts.display(100, fahrenheit: true) == 100)
    }

    @Test func axisLabelsCarryUnitSuffix() {
        #expect(MetricUnit.temperature.axisLabel(40) == "40°")
        #expect(MetricUnit.rpm.axisLabel(900) == "900")
        #expect(MetricUnit.watts.axisLabel(20) == "20W")
        #expect(MetricUnit.percent.axisLabel(50) == "50%")
        #expect(MetricUnit.gigabytes.axisLabel(8) == "8G")
    }

    @Test func onlyRPMAndPercentStartAtZero() {
        #expect(MetricUnit.rpm.includesZero)
        #expect(MetricUnit.percent.includesZero)
        #expect(!MetricUnit.temperature.includesZero)
        #expect(!MetricUnit.watts.includesZero)
    }
}

@Suite struct MetricTests {
    @Test func temperatureMetricUsesComponentAndTemperatureColors() {
        let metric = Metric.temperature(.gpu)
        #expect(metric.key == "gpu")
        #expect(metric.title == "GPU")
        #expect(metric.peakLabel == "Hottest sensor")
        #expect(metric.tint(for: 85) == .red)
    }

    @Test func thresholdTints() {
        #expect(Metric.cpuUsage.tint(for: 10) == .green)
        #expect(Metric.cpuUsage.tint(for: 60) == .orange)
        #expect(Metric.cpuUsage.tint(for: 85) == .red)
    }

    @Test func metricsWithoutThresholdsUsePrimary() {
        #expect(Metric.systemPower.tint(for: 500) == .primary)
    }

    @Test func fanMetricIsOneBasedForDisplay() {
        #expect(Metric.fan(0).key == "fan0")
        #expect(Metric.fan(0).title == "Fan 1")
        #expect(Metric.fan(0).id == "fan0")
    }
}

@Suite struct MetricSnapshotTests {
    @Test func componentsRecordAverageAndHottest() {
        let snapshot = MetricSnapshot(summaries: ComponentSummary.summarize([reading("a", .cpu, 40), reading("b", .cpu, 60)]))
        #expect(snapshot.average == ["cpu": 50])
        #expect(snapshot.peak == ["cpu": 60])
    }

    @Test func instantaneousValuesAreBothAverageAndPeak() {
        let snapshot = MetricSnapshot(
            fans: [FanReading(index: 1, rpm: 2000, min: 0, max: 0)],
            power: PowerReading(cpu: 5, gpu: 3, ane: 0, dram: 1, system: 20),
            usage: UsageReading(cpu: 30, performanceCores: 0, efficiencyCores: 0, gpu: 12),
            memory: MemoryReading(used: 8e9, total: 16e9, pressure: 0, swapUsed: 0),
            battery: BatteryReading(properties: ["CurrentCapacity": 80, "Voltage": 12000, "Amperage": 1000]))
        let expected: [String: Double] = [
            "fan1": 2000, "power.system": 20, "power.cpu": 5, "power.gpu": 3, "power.ane": 0, "power.dram": 1,
            "usage.cpu": 30, "usage.gpu": 12, "mem.used": 8, "battery.charge": 80, "battery.watts": 12,
        ]
        #expect(snapshot.average == expected)
        #expect(snapshot.peak == expected)
    }

    @Test func missingReadingsAreLeftOut() {
        let snapshot = MetricSnapshot(power: PowerReading(), usage: UsageReading(cpu: 1, performanceCores: 0, efficiencyCores: 0))
        #expect(snapshot.average["power.system"] == nil)
        #expect(snapshot.average["usage.gpu"] == nil)
        #expect(snapshot.average["usage.cpu"] == 1)
        #expect(MetricSnapshot().average.isEmpty)
    }
}
