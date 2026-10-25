import Foundation
import Testing
@testable import TempMonitor

@Suite struct SensorClassifierTests {
    @Test(arguments: [
        ("NAND CH0 temp", Component.ssd, "SSD controller"),
        ("gas gauge battery", .battery, "Battery cell"),
        ("GPU MTR Temp Sensor1", .gpu, "GPU"),
        ("pACC MTR Temp Sensor2", .cpu, "Performance cores"),
        ("eACC MTR Temp Sensor0", .cpu, "Efficiency cores"),
        ("SOC MTR Temp Sensor0", .cpu, "SoC"),
        ("ANE MTR Temp Sensor1", .cpu, "SoC"),
        ("PMU2 TP3g", .gpu, "GPU hotspot 3"),
        ("PMU TP1s", .cpu, "CPU hotspot 1"),
        ("PMU tdie3", .cpu, "CPU die 3"),
        ("PMU tdev5", .board, "Power/board 5"),
        ("Mystery sensor", .other, "Mystery sensor"),
    ])
    func classifies(raw: String, component: Component, name: String) {
        #expect(SensorClassifier.classify(raw) == SensorClassifier.Kind(component: component, name: name))
    }

    @Test func hidesCalibrationSensors() {
        #expect(SensorClassifier.classify("PMU tcal") == nil)
    }
}

@Suite struct SensorAssemblyTests {
    @Test func dropsImplausibleAndHiddenSensors() {
        let readings = SensorReader.assemble([
            RawSensorValue(name: "GPU MTR Temp Sensor1", celsius: 0),
            RawSensorValue(name: "NAND CH0 temp", celsius: 200),
            RawSensorValue(name: "PMU tcal", celsius: 50),
            RawSensorValue(name: "gas gauge battery", celsius: 31),
        ], coreReadings: [])
        #expect(readings.map(\.name) == ["Battery cell"])
    }

    @Test func disambiguatesRepeatedNames() {
        let readings = SensorReader.assemble([
            RawSensorValue(name: "NAND CH0 temp", celsius: 40),
            RawSensorValue(name: "NAND CH0 temp", celsius: 41),
            RawSensorValue(name: "NAND CH0 temp", celsius: 42),
        ], coreReadings: [])
        #expect(Set(readings.map(\.id)) == ["NAND CH0 temp", "NAND CH0 temp#1", "NAND CH0 temp#2"])
        #expect(readings.allSatisfy { $0.raw == "NAND CH0 temp" })
    }

    @Test func keepsHIDCoreSensorsWhenThereAreNoSMCCores() {
        let readings = SensorReader.assemble([RawSensorValue(name: "PMU tdie1", celsius: 50)], coreReadings: [])
        #expect(readings == [Reading(id: "PMU tdie1", raw: "PMU tdie1", name: "CPU die 1", component: .cpu, celsius: 50)])
    }

    @Test func relabelsHIDCoreSensorsAsPMUWhenSMCCoresExist() {
        let core = Reading(id: "smc.Tp01", raw: "Tp01", name: "CPU core 1", component: .cpu, celsius: 60)
        let readings = SensorReader.assemble([
            RawSensorValue(name: "PMU tdie1", celsius: 50),
            RawSensorValue(name: "PMU2 TP3g", celsius: 45),
            RawSensorValue(name: "NAND CH0 temp", celsius: 40),
        ], coreReadings: [core])
        #expect(readings.map(\.name) == ["CPU core 1", "SSD controller", "PMU CPU die 1", "PMU GPU hotspot 3"])
        #expect(readings.map(\.component) == [.cpu, .ssd, .board, .board])
    }
}

@Suite struct SMCDecodingTests {
    @Test func fourCharCodes() {
        #expect(SMC.fourCharCode("FNum") == 0x464E_756D)
        #expect(SMC.fourCharCode("abc") == nil)
        #expect(SMC.fourCharCode("toolong") == nil)
        #expect(SMC.fourCharString(0x464E_756D) == "FNum")
        #expect(SMC.fourCharString(SMC.fourCharCode("sp78")!) == "sp78")
    }

    @Test func decodesKnownTypes() {
        #expect(SMC.decode([0x00, 0x00, 0xC0, 0x3F], type: "flt ") == 1.5)   // little-endian Float
        #expect(SMC.decode([7], type: "ui8 ") == 7)
        #expect(SMC.decode([0x01, 0x02], type: "ui16") == 258)
        #expect(SMC.decode([0x00, 0x00, 0x01, 0x00], type: "ui32") == 256)
        #expect(SMC.decode([0x17, 0x70], type: "fpe2") == 1500)
        #expect(SMC.decode([0x28, 0x80], type: "sp78") == 40.5)
        #expect(SMC.decode([0xFF, 0x00], type: "sp78") == -1)
    }

    @Test func rejectsShortDataAndUnknownTypes() {
        #expect(SMC.decode([0x00, 0x00], type: "flt ") == nil)
        #expect(SMC.decode([], type: "ui8 ") == nil)
        #expect(SMC.decode([0x01], type: "ui16") == nil)
        #expect(SMC.decode([0x01, 0x02, 0x03, 0x04], type: "ch8*") == nil)
    }
}

@Suite struct FanTests {
    @Test func readsEveryFan() {
        let smc = FakeSMC(["FNum": 2, "F0Ac": 1200, "F0Mn": 1000, "F0Mx": 5000, "F1Ac": -5])
        #expect(FanReader.read(smc) == [
            FanReading(index: 0, rpm: 1200, min: 1000, max: 5000),
            FanReading(index: 1, rpm: 0, min: 0, max: 0),
        ])
    }

    @Test func skipsFansWithoutASpeed() {
        #expect(FanReader.read(FakeSMC(["FNum": 2, "F1Ac": 900])).map(\.index) == [1])
    }

    @Test func noFans() {
        #expect(FanReader.read(FakeSMC([:])).isEmpty)
        #expect(FanReader.read(FakeSMC(["FNum": 0])).isEmpty)
    }

    @Test(arguments: [(3000.0, 0.5), (500.0, 0.0), (9000.0, 1.0)])
    func fractionIsClampedBetweenMinAndMax(rpm: Double, fraction: Double) {
        #expect(FanReading(index: 0, rpm: rpm, min: 1000, max: 5000).fraction == fraction)
    }

    @Test func fractionIsZeroWithoutARange() {
        #expect(FanReading(index: 0, rpm: 3000, min: 0, max: 0).fraction == 0)
    }
}

@Suite struct SMCTemperatureTests {
    @Test func noKnownSensorsMeansNoReader() {
        #expect(SMCTemperatures(smc: FakeSMC(["Tp01": 0])) == nil)
    }

    @Test func readsAndNamesCoreSensors() {
        let smc = FakeSMC(["Tp01": 45, "Tp05": 47, "Tg05": 50])
        let reader = SMCTemperatures(smc: smc)
        #expect(reader?.read() == [
            Reading(id: "smc.Tp01", raw: "Tp01", name: "CPU core 1", component: .cpu, celsius: 45),
            Reading(id: "smc.Tp05", raw: "Tp05", name: "CPU core 2", component: .cpu, celsius: 47),
            Reading(id: "smc.Tg05", raw: "Tg05", name: "GPU core 1", component: .gpu, celsius: 50),
        ])
    }

    @Test func dropsImplausibleValuesOnLaterReads() {
        let smc = FakeSMC(["Tp01": 45, "Tp05": 47])
        let reader = SMCTemperatures(smc: smc)
        smc.values["Tp01"] = 300
        #expect(reader?.read().map(\.name) == ["CPU core 1"])
        #expect(reader?.read().first?.raw == "Tp05")
    }
}

@Suite struct PowerTests {
    @Test(arguments: [
        ("GPU Energy", \PowerReading.gpu), ("GPU0", \.gpu), ("GPU", \.gpu),
        ("CPU Energy", \.cpu), ("EACC_CPU", \.cpu), ("PACC0_CPU", \.cpu), ("PACC1_CPU", \.cpu),
        ("ANE0", \.ane), ("DRAM0", \.dram),
    ])
    func assignsChannelsToComponents(channel: String, component: KeyPath<PowerReading, Double>) {
        var reading = PowerReading()
        reading.add(channel: channel, watts: 2)
        #expect(reading[keyPath: component] == 2)
    }

    @Test(arguments: ["PACC0_CPU0", "GPU0 SRAM", "DISP", "ISP"])
    func ignoresPerCoreAndOtherChannels(channel: String) {
        var reading = PowerReading()
        reading.add(channel: channel, watts: 2)
        #expect(reading == PowerReading())
    }

    @Test func channelsAccumulate() {
        var reading = PowerReading()
        reading.add(channel: "EACC_CPU", watts: 1)
        reading.add(channel: "PACC0_CPU", watts: 2.5)
        #expect(reading.cpu == 3.5)
    }

    @Test func convertsEnergyUnitsToJoules() {
        #expect(PowerReader.joules(5_000_000_000, unit: "nJ") == 5)
        #expect(PowerReader.joules(5_000_000, unit: "uJ") == 5)
        #expect(PowerReader.joules(5_000_000, unit: "µJ") == 5)
        #expect(PowerReader.joules(5_000, unit: " mJ ") == 5)
        #expect(PowerReader.joules(5_000, unit: "??") == 5)
    }

    @Test func systemEstimatePrefersSMCValue() {
        #expect(PowerReading(cpu: 5, gpu: 3, system: 20).bestSystemEstimate == 20)
        #expect(PowerReading(cpu: 5, gpu: 3).bestSystemEstimate == 8)
    }
}

@Suite struct UsageTests {
    // Tick order is CPU_STATE_USER, SYSTEM, IDLE, NICE.
    @Test func computesBusyShareSincePreviousTicks() throws {
        let usage = try #require(UsageReading.from(
            ticks: [[40, 10, 50, 0], [10, 5, 80, 5]],
            previous: [[0, 0, 0, 0], [0, 0, 0, 0]],
            efficiencyCount: 1, gpu: 12))
        #expect(usage.efficiencyCores == 50)
        #expect(usage.performanceCores == 20)
        #expect(usage.cpu == 35)
        #expect(usage.gpu == 12)
    }

    @Test func handlesCounterWraparound() {
        // The user counter wrapped from UInt32.max - 9 to 10: 20 busy ticks against 20 idle ones.
        let usage = UsageReading.from(ticks: [[10, 0, 20, 0]], previous: [[UInt32.max - 9, 0, 0, 0]], efficiencyCount: 0, gpu: nil)
        #expect(usage?.cpu == 50)
    }

    @Test func idleCoreWithNoTicksIsZero() {
        let usage = UsageReading.from(ticks: [[5, 0, 0, 0]], previous: [[5, 0, 0, 0]], efficiencyCount: 0, gpu: nil)
        #expect(usage?.cpu == 0)
    }

    @Test func needsMatchingSnapshots() {
        #expect(UsageReading.from(ticks: [[1, 0, 0, 0]], previous: [], efficiencyCount: 0, gpu: nil) == nil)
        #expect(UsageReading.from(ticks: [], previous: [], efficiencyCount: 0, gpu: nil) == nil)
    }

    @Test func efficiencyCountLargerThanCoreCount() {
        let usage = UsageReading.from(ticks: [[1, 0, 1, 0]], previous: [[0, 0, 0, 0]], efficiencyCount: 4, gpu: nil)
        #expect(usage?.efficiencyCores == 50)
        #expect(usage?.performanceCores == 0)
    }
}

@Suite struct MemoryAndThermalTests {
    @Test func memoryInGigabytes() {
        let memory = MemoryReading(used: 8e9, total: 16e9, pressure: 30, swapUsed: 5e8)
        #expect(memory.usedGigabytes == 8)
        #expect(memory.totalGigabytes == 16)
        #expect(memory.swapGigabytes == 0.5)
    }

    @Test func thermalStates() {
        #expect(ProcessInfo.ThermalState.nominal.title == "Nominal")
        #expect(ProcessInfo.ThermalState.fair.title == "Fair")
        #expect(ProcessInfo.ThermalState.serious.title == "Serious")
        #expect(ProcessInfo.ThermalState.critical.title == "Critical")
        #expect(!ProcessInfo.ThermalState.nominal.mayBeThrottling)
        #expect(ProcessInfo.ThermalState.fair.mayBeThrottling)
    }
}

@Suite struct BatteryTests {
    private let base: [String: Any] = [
        "CurrentCapacity": 80, "AppleRawMaxCapacity": 4500, "DesignCapacity": 5000, "CycleCount": 120,
        "IsCharging": true, "ExternalConnected": true, "Voltage": 12000, "InstantAmperage": 2500,
        "AdapterDetails": ["Watts": 96], "TimeRemaining": 65,
    ]

    private func battery(_ changes: [String: Any] = [:], removing: [String] = []) -> BatteryReading? {
        var dict = base.merging(changes) { $1 }
        for key in removing { dict[key] = nil }
        return BatteryReading(properties: dict)
    }

    @Test func parsesRegistryProperties() throws {
        let b = try #require(battery())
        #expect(b.charge == 80)
        #expect(b.health == 90)
        #expect(b.cycleCount == 120)
        #expect(b.isCharging)
        #expect(b.pluggedIn)
        #expect(b.watts == 30)
        #expect(b.adapterWatts == 96)
        #expect(b.minutesRemaining == 65)
    }

    @Test func needsAChargeLevel() {
        #expect(battery(removing: ["CurrentCapacity"]) == nil)
    }

    @Test func restoresTheSignOfDischargeCurrent() {
        let b = battery(["InstantAmperage": NSNumber(value: UInt64(bitPattern: -2000)), "IsCharging": false])
        #expect(b?.watts == -24)
    }

    @Test func fallsBackToAverageAmperage() {
        #expect(battery(["Amperage": 1000], removing: ["InstantAmperage"])?.watts == 12)
    }

    @Test func healthIsCappedAndNeedsDesignCapacity() {
        #expect(battery(["AppleRawMaxCapacity": 6000])?.health == 100)
        #expect(battery(["DesignCapacity": 0])?.health == nil)
    }

    @Test(arguments: [0, 65535, -1])
    func estimatingTimeRemainingIsUnknown(minutes: Int) {
        #expect(battery(["TimeRemaining": minutes])?.minutesRemaining == nil)
    }

    @Test func statusText() {
        #expect(battery()?.statusText == "Charging · 1h 5m to full")
        #expect(battery(["IsCharging": false, "ExternalConnected": false])?.statusText == "On battery · 1h 5m left")
        #expect(battery(["IsCharging": false], removing: ["TimeRemaining"])?.statusText == "Plugged in")
    }

    @Test func flowText() {
        #expect(battery()?.flowText == "Into battery")
        #expect(battery(["InstantAmperage": -1])?.flowText == "Out of battery")
    }
}
