import Foundation
import SwiftUI
import Testing
@testable import TempMonitor

@Suite struct TemperatureTests {
    @Test func displayConvertsToFahrenheitOnlyWhenAsked() {
        #expect(Temperature.display(100, fahrenheit: true) == 212)
        #expect(Temperature.display(0, fahrenheit: true) == 32)
        #expect(Temperature.display(37, fahrenheit: false) == 37)
    }

    @Test func formatRoundsAndAddsUnit() {
        #expect(Temperature.format(58.4, fahrenheit: false) == "58°C")
        #expect(Temperature.format(100, fahrenheit: true) == "212°F")
        #expect(Temperature.format(58.6, fahrenheit: false, showUnit: false) == "59°")
    }

    @Test(arguments: [
        (59.9, Color.green), (60.0, Color.orange), (79.9, Color.orange), (80.0, Color.red), (120.0, Color.red),
    ])
    func colorFollowsThresholds(celsius: Double, expected: Color) {
        #expect(Temperature.color(for: celsius) == expected)
    }
}

@Suite struct DurationFormatTests {
    @Test(arguments: [(0.0, "0:00"), (65.0, "1:05"), (59.6, "1:00"), (600.0, "10:00"), (3599.0, "59:59")])
    func clockFormatsMinutesAndSeconds(seconds: Double, expected: String) {
        #expect(DurationFormat.clock(seconds) == expected)
    }
}

@Suite struct MeanTests {
    @Test func emptyArrayHasNoMean() {
        #expect([Double]().mean == nil)
        #expect([Double]()[...].mean == nil)
    }

    @Test func meanOfValues() {
        #expect([1.0, 2, 3, 6].mean == 3)
        #expect([1.0, 2, 3, 6][1...2].mean == 2.5)
    }
}

@Suite struct JSONFileTests {
    @Test func missingFileLoadsNil() {
        #expect(JSONFile<[Int]>(url: temporaryFileURL()).load() == nil)
    }

    @Test func savesIntoNewFolderAndLoadsBack() {
        let file = JSONFile<[HistorySample]>(url: temporaryFileURL())
        let samples = [HistorySample(t: referenceDate, avg: ["cpu": 50], max: ["cpu": 60])]
        file.save(samples)
        #expect(file.load() == samples)
    }

    @Test func writesDatesAsSecondsSince1970() throws {
        let url = temporaryFileURL()
        JSONFile<[HistorySample]>(url: url).save([HistorySample(t: referenceDate, avg: [:], max: [:])])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"t\":1200000"))
    }

    @Test func corruptFileLoadsNil() throws {
        let url = temporaryFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(JSONFile<[Int]>(url: url).load() == nil)
    }

    @Test func appSupportFileIsInsideTempMonitorFolder() {
        let url = AppSupport.file("history.json")
        #expect(url.lastPathComponent == "history.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "TempMonitor")
    }
}
