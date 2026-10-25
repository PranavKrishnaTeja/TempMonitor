import Foundation
import Testing
@testable import TempMonitor

@Suite struct MinuteBucketTests {
    @Test func startsAtTheBeginningOfTheMinute() {
        let bucket = MinuteBucket(containing: referenceDate.addingTimeInterval(42))
        #expect(bucket.start == referenceDate)
        #expect(bucket.contains(referenceDate))
        #expect(bucket.contains(referenceDate.addingTimeInterval(59.9)))
        #expect(!bucket.contains(referenceDate.addingTimeInterval(60)))
        #expect(!bucket.contains(referenceDate.addingTimeInterval(-1)))
    }

    @Test func emptyBucketHasNoSample() {
        #expect(MinuteBucket(containing: referenceDate).sample == nil)
    }

    @Test func averagesAveragesAndKeepsPeaks() {
        var bucket = MinuteBucket(containing: referenceDate)
        bucket.add(avg: ["cpu": 40, "gpu": 30], max: ["cpu": 50, "gpu": 35])
        bucket.add(avg: ["cpu": 45], max: ["cpu": 70])
        let sample = bucket.sample
        #expect(sample?.t == referenceDate)
        #expect(sample?.avg == ["cpu": 42.5, "gpu": 30])
        #expect(sample?.max == ["cpu": 70, "gpu": 35])
    }

    @Test func roundsToOneDecimal() {
        var bucket = MinuteBucket(containing: referenceDate)
        bucket.add(avg: ["cpu": 1.0 / 3], max: ["cpu": 2.0 / 3])
        #expect(bucket.sample?.avg["cpu"] == 0.3)
        #expect(bucket.sample?.max["cpu"] == 0.7)
    }
}

@Suite struct DownsamplerTests {
    private func points(at offsets: [TimeInterval], value: (TimeInterval) -> Double = { $0 }) -> [Downsampler.RawPoint] {
        offsets.map { Downsampler.RawPoint(t: referenceDate.addingTimeInterval($0), avg: value($0), max: value($0) + 1) }
    }

    @Test func emptyInputGivesNoPoints() {
        #expect(Downsampler.downsample([], range: .hour, maxPoints: 300).isEmpty)
    }

    @Test func groupsPointsIntoTimeBins() {
        // 1 hour / 300 points = 12 s bins, so samples every 2 s fall six to a bin.
        let result = Downsampler.downsample(points(at: stride(from: 0, to: 24, by: 2).map { $0 }), range: .hour, maxPoints: 300)
        #expect(result.count == 2)
        #expect(result[0].t == referenceDate.addingTimeInterval(6))   // middle sample of the bin
        #expect(result[0].avg == 5)                                    // mean of 0, 2, ... 10
        #expect(result[0].max == 11)                                   // peak of 1, 3, ... 11
        #expect(result[1].avg == 17)
        #expect(result.allSatisfy { $0.segment == 0 })
    }

    @Test func startsNewSegmentAfterAGap() {
        let result = Downsampler.downsample(points(at: [0, 2, 4, 200, 202]), range: .hour, maxPoints: 300)
        #expect(result.map(\.segment) == [0, 1])
    }

    @Test func shortPausesDoNotBreakTheLine() {
        // 30 s is the shortest gap that counts on the 1H range.
        let result = Downsampler.downsample(points(at: [0, 24, 48]), range: .hour, maxPoints: 300)
        #expect(result.map(\.segment) == [0, 0, 0])
    }

    @Test func longerRangesTolerateLongerGaps() {
        // On 7D, bins are 2016 s and gaps under 3 bins are bridged.
        let result = Downsampler.downsample(points(at: [0, 3000, 30000]), range: .week, maxPoints: 300)
        #expect(result.map(\.segment) == [0, 0, 1])
    }
}

@Suite struct SeriesStatsTests {
    @Test func emptySeries() {
        let stats = SeriesStats([])
        #expect(stats.average == nil)
        #expect(stats.peak == nil)
    }

    @Test func averageAndPeak() {
        let points = [
            HistoryPoint(t: referenceDate, avg: 10, max: 15, segment: 0),
            HistoryPoint(t: referenceDate.addingTimeInterval(60), avg: 20, max: 40, segment: 0),
            HistoryPoint(t: referenceDate.addingTimeInterval(120), avg: 30, max: 35, segment: 0),
        ]
        let stats = SeriesStats(points)
        #expect(stats.average == 20)
        #expect(stats.peak == points[1])
    }
}

@Suite struct HistoryRangeTests {
    @Test func durations() {
        #expect(HistoryRange.hour.seconds == 3600)
        #expect(HistoryRange.sixHours.seconds == 21600)
        #expect(HistoryRange.day.seconds == 86400)
        #expect(HistoryRange.week.seconds == 604800)
        #expect(HistoryRange.week.seconds == HistoryStore.retention)
        #expect(HistoryRange.allCases.map(\.id) == ["1H", "6H", "24H", "7D"])
    }
}

@Suite struct HistoryStoreTests {
    @Test func newStoreIsEmpty() {
        let store = HistoryStore(fileURL: temporaryFileURL())
        #expect(store.minutes.isEmpty)
        #expect(store.series(key: "cpu", range: .hour).isEmpty)
    }

    @Test func recentSamplesAreChartedAtFullResolution() {
        let clock = TestClock()
        let store = HistoryStore(fileURL: temporaryFileURL(), now: { clock.now })
        for i in 0..<3 {
            store.record(avg: ["cpu": Double(40 + i)], max: ["cpu": Double(50 + i)], at: referenceDate.addingTimeInterval(Double(i) * 20))
        }
        let series = store.series(key: "cpu", range: .hour, now: referenceDate.addingTimeInterval(60))
        #expect(series.map(\.avg) == [40, 41, 42])
        #expect(series.map(\.max) == [50, 51, 52])
    }

    @Test func seriesSkipsSamplesWithoutTheKey() {
        let store = HistoryStore(fileURL: temporaryFileURL())
        store.record(avg: ["gpu": 1], max: ["gpu": 1], at: referenceDate)
        #expect(store.series(key: "cpu", range: .hour, now: referenceDate).isEmpty)
    }

    @Test func completedMinutesAreAggregated() {
        let store = HistoryStore(fileURL: temporaryFileURL())
        store.record(avg: ["cpu": 40], max: ["cpu": 45], at: referenceDate)
        store.record(avg: ["cpu": 50], max: ["cpu": 60], at: referenceDate.addingTimeInterval(30))
        #expect(store.minutes.isEmpty)   // the minute isn't over yet

        store.record(avg: ["cpu": 99], max: ["cpu": 99], at: referenceDate.addingTimeInterval(60))
        #expect(store.minutes == [HistorySample(t: referenceDate, avg: ["cpu": 45], max: ["cpu": 60])])
    }

    @Test func saveNowPersistsThePartialMinute() {
        let url = temporaryFileURL()
        let clock = TestClock()
        let store = HistoryStore(fileURL: url, now: { clock.now })
        store.record(avg: ["cpu": 40], max: ["cpu": 45], at: referenceDate)
        store.saveNow()

        let reopened = HistoryStore(fileURL: url, now: { clock.now })
        #expect(reopened.minutes == [HistorySample(t: referenceDate, avg: ["cpu": 40], max: ["cpu": 45])])
    }

    @Test func loadingDropsExpiredSamplesAndSorts() {
        let url = temporaryFileURL()
        let old = HistorySample(t: referenceDate.addingTimeInterval(-HistoryStore.retention - 60), avg: ["cpu": 1], max: ["cpu": 1])
        let later = HistorySample(t: referenceDate.addingTimeInterval(-60), avg: ["cpu": 3], max: ["cpu": 3])
        let earlier = HistorySample(t: referenceDate.addingTimeInterval(-120), avg: ["cpu": 2], max: ["cpu": 2])
        JSONFile<[HistorySample]>(url: url).save([later, old, earlier])

        let store = HistoryStore(fileURL: url, now: { referenceDate })
        #expect(store.minutes == [earlier, later])
    }

    @Test func olderRangesCombineSavedMinutesWithRecentSamples() {
        let url = temporaryFileURL()
        let threeHoursAgo = referenceDate.addingTimeInterval(-3 * 3600)
        JSONFile<[HistorySample]>(url: url).save([HistorySample(t: threeHoursAgo, avg: ["cpu": 30], max: ["cpu": 35])])

        let store = HistoryStore(fileURL: url, now: { referenceDate })
        store.record(avg: ["cpu": 50], max: ["cpu": 55], at: referenceDate)

        #expect(store.series(key: "cpu", range: .hour, now: referenceDate).map(\.avg) == [50])
        let sixHours = store.series(key: "cpu", range: .sixHours, now: referenceDate)
        #expect(sixHours.map(\.avg) == [30, 50])
        #expect(sixHours.map(\.segment) == [0, 1])
    }

    @Test func recentSamplesOlderThanAnHourAreDropped() {
        let store = HistoryStore(fileURL: temporaryFileURL())
        store.record(avg: ["cpu": 1], max: ["cpu": 1], at: referenceDate)
        store.record(avg: ["cpu": 2], max: ["cpu": 2], at: referenceDate.addingTimeInterval(3700))
        // The first sample is now only available as its 1-minute aggregate.
        let series = store.series(key: "cpu", range: .day, now: referenceDate.addingTimeInterval(3700))
        #expect(series.map(\.avg) == [1, 2])
        #expect(store.minutes.count == 1)
    }
}
