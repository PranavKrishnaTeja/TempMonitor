import Foundation
import Testing
@testable import TempMonitor

/// These read this Mac's real sensors, so they check only what holds on any Apple Silicon Mac.
@Suite(.serialized) struct HardwareSmokeTests {
    @Test func readsTemperatureSensors() {
        let readings = SensorReader.readAll(coreReadings: SMC().flatMap(SMCTemperatures.init)?.read() ?? [])
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { Reading.isPlausible($0.celsius) })
        #expect(readings == readings.sorted(by: Reading.displayOrder))
    }

    @Test func readsTheSMC() throws {
        let smc = try #require(SMC())
        #expect(smc.read("abc") == nil)
        #expect(smc.read("ZZZZ") == nil)
        for fan in FanReader.read(smc) {
            #expect(fan.rpm >= 0)
        }
    }

    @Test func readsPowerOnTheSecondCall() throws {
        let reader = try #require(PowerReader())
        Thread.sleep(forTimeInterval: 0.2)
        let power = try #require(reader.read(smc: SMC()))
        #expect(power.cpu >= 0)
        #expect(power.gpu >= 0)
    }

    @Test func readsUsageOnTheSecondCall() throws {
        let reader = SystemStatsReader()
        #expect(reader.readUsage() == nil)
        Thread.sleep(forTimeInterval: 0.2)
        let usage = try #require(reader.readUsage())
        #expect((0...100).contains(usage.cpu))
    }

    @Test func readsMemory() throws {
        let memory = try #require(SystemStatsReader().readMemory())
        #expect(memory.total == Double(ProcessInfo.processInfo.physicalMemory))
        #expect(memory.used > 0 && memory.used <= memory.total)
        #expect((0...100).contains(memory.pressure))
    }

    @Test func readsSysctl() {
        #expect((SystemStatsReader.sysctlInt("hw.ncpu") ?? 0) > 0)
        #expect(SystemStatsReader.sysctlInt("no.such.key") == nil)
    }

    @Test func readsBatteryIfThereIsOne() {
        guard let battery = BatteryReader.read() else { return }   // desktops have no battery
        #expect((0...100).contains(battery.charge))
    }

    @MainActor
    @Test func monitorStoreRefreshPublishesReadings() {
        let store = MonitorStore(history: HistoryStore(fileURL: temporaryFileURL()), stressReportsURL: temporaryFileURL())
        store.refresh()
        #expect(!store.summaries.isEmpty)
        #expect(store.memory != nil)
        #expect(store.usage != nil)
        let cpu = store.summary(for: .cpu)
        #expect(store.latest["cpu"] == cpu?.hottest)
        #expect(store.readings(for: .cpu).count == cpu?.sensorCount)
        #expect(MenuBarMode.cpuGpu.text(for: store.summaries, fahrenheit: false) != MenuBarMode.placeholder)
        #expect(!store.lastHour(of: .temperature(.cpu)).isEmpty)
        #expect(store.stress.reports.isEmpty)
    }
}

/// Briefly runs the real load generator. This pegs the CPU and GPU for a few seconds.
@Suite(.serialized) struct LoadGeneratorTests {
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return condition()
    }

    @Test func gpuLoadCountsWork() throws {
        let load = try LoadGenerator(target: .gpu)
        load.start()
        defer { load.stop() }
        #expect(waitFor { load.counts.gpu > 0 })
        #expect(load.counts.cpu == 0)
    }

    @Test func cpuLoadCountsWorkAndStops() throws {
        let load = try LoadGenerator(target: .cpu)
        load.start()
        #expect(waitFor { load.counts.cpu > 0 })
        load.stop()
        let afterStop = load.counts.cpu
        // Threads finish their current chunk, then stop counting.
        Thread.sleep(forTimeInterval: 3)
        let settled = load.counts.cpu
        Thread.sleep(forTimeInterval: 1)
        #expect(load.counts.cpu == settled)
        #expect(settled >= afterStop)
        #expect(load.counts.gpu == 0)
    }

    @Test func errorsDescribeTheProblem() {
        #expect(LoadGenerator.LoadError.noGPU.errorDescription == "No Metal GPU available.")
        #expect(LoadGenerator.LoadError.shader("boom").errorDescription == "GPU load failed to start: boom")
    }
}
