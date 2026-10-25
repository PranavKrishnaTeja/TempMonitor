import SwiftUI
import Charts

/// History chart for one metric: average and peak over the selected range.
struct DetailView: View {
    @ObservedObject var store: MonitorStore
    let metric: Metric
    let onBack: () -> Void

    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false
    @State private var range: HistoryRange = .hour
    @State private var hovered: HistoryPoint?

    private let avgColor = Color.accentColor
    private let peakColor = Color.red

    var body: some View {
        let points = store.history.series(key: metric.key, range: range)
        let stats = SeriesStats(points)
        let current = store.latest[metric.key]

        VStack(alignment: .leading, spacing: 10) {
            header(current: current)

            Picker("", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            legend.font(.caption)

            if points.isEmpty {
                Text("No data yet for this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                chart(points)
                    .frame(height: 180)
            }

            HStack {
                stat("Now", current.map(format))
                Spacer()
                stat("Average", stats.average.map(format))
                Spacer()
                stat("Peak", stats.peak.map { format($0.max) },
                     detail: stats.peak.map { $0.t.formatted(range == .week ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute()) })
            }

            Text("History is kept for 7 days at 1-minute resolution.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func header(current: Double?) -> some View {
        HStack {
            BackButton(action: onBack)
            Spacer()
            Image(systemName: metric.symbol)
            Text(metric.title).font(.headline)
            Spacer()
            Text(current.map(format) ?? MenuBarMode.placeholder)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(current.map { metric.tint(for: $0) } ?? .secondary)
        }
    }

    @ViewBuilder private var legend: some View {
        HStack {
            if let h = hovered {
                Text(h.t, format: range == .week ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                Spacer()
                legendDot(avgColor)
                Text("avg \(format(h.avg))")
                legendDot(peakColor)
                Text("peak \(format(h.max))")
            } else {
                legendDot(avgColor)
                Text("Average")
                legendDot(peakColor)
                Text(metric.peakLabel)
                Spacer()
            }
        }
    }

    private func format(_ v: Double) -> String {
        metric.unit.format(v, fahrenheit: useFahrenheit)
    }

    private func display(_ v: Double) -> Double {
        metric.unit.display(v, fahrenheit: useFahrenheit)
    }

    private func chart(_ points: [HistoryPoint]) -> some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Average", display(p.avg)),
                         series: .value("Series", "avg\(p.segment)"))
                    .foregroundStyle(avgColor)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.t), y: .value("Peak", display(p.max)),
                         series: .value("Series", "max\(p.segment)"))
                    .foregroundStyle(peakColor.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .interpolationMethod(.monotone)
            }
            if let h = hovered {
                RuleMark(x: .value("Time", h.t)).foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("Time", h.t), y: .value("Peak", display(h.max)))
                    .foregroundStyle(peakColor)
                    .symbolSize(30)
                PointMark(x: .value("Time", h.t), y: .value("Average", display(h.avg)))
                    .foregroundStyle(avgColor)
                    .symbolSize(30)
            }
        }
        .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
        .chartYScale(domain: .automatic(includesZero: metric.unit.includesZero))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(metric.unit.axisLabel(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geo[proxy.plotAreaFrame].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            hovered = points.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    private func legendDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private func stat(_ title: String, _ value: String?, detail: String? = nil) -> some View {
        StatView(title: title, value: value, detail: detail, valueFont: .system(.body, design: .monospaced))
    }
}
