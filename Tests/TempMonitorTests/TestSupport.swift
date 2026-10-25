import Foundation
@testable import TempMonitor

/// A fixed point in time that's a whole number of minutes (and of 12 s chart bins) since 1970.
let referenceDate = Date(timeIntervalSince1970: 1_200_000)

/// A unique file path in the temporary directory, in a folder that doesn't exist yet.
func temporaryFileURL(_ name: String = "test.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TempMonitorTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

/// A clock tests can move forward by hand.
final class TestClock {
    var now: Date

    init(_ start: Date = referenceDate) { now = start }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// An SMC backed by a dictionary of key values.
final class FakeSMC: SMCKeyReading {
    var values: [String: Double]

    init(_ values: [String: Double]) { self.values = values }

    func read(_ key: String) -> Double? { values[key] }
}

func reading(_ name: String, _ component: Component, _ celsius: Double) -> Reading {
    Reading(id: name, raw: name, name: name, component: component, celsius: celsius)
}
