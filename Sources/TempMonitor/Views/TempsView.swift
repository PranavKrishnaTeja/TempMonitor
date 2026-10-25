import SwiftUI

/// The Temps tab: one row per component, plus every raw sensor.
struct TempsView: View {
    @ObservedObject var store: MonitorStore
    let fahrenheit: Bool
    let onSelect: (Metric) -> Void
    @State private var showAllSensors = false

    var body: some View {
        if store.summaries.isEmpty {
            Text("No sensors found.").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 2) {
                ForEach(store.summaries) { summaryRow($0) }
            }
            Text("Click a component to see its history.").font(.caption2).foregroundStyle(.secondary)

            DisclosureGroup("All sensors (\(store.readings.count))", isExpanded: $showAllSensors) {
                ScrollView { allSensors }
                    .frame(maxHeight: 240)
            }
            .font(.caption)
        }
    }

    private func summaryRow(_ summary: ComponentSummary) -> some View {
        let metric = Metric.temperature(summary.component)
        return MetricRow(metric: metric, value: summary.hottest, subtitle: subtitle(for: summary),
                         history: store.lastHour(of: metric), fahrenheit: fahrenheit) { onSelect(metric) }
    }

    private func subtitle(for summary: ComponentSummary) -> String {
        let sensors = summary.sensorCount == 1 ? "sensor" : "sensors"
        return "avg \(Temperature.format(summary.average, fahrenheit: fahrenheit)) · \(summary.sensorCount) \(sensors)"
    }

    private var allSensors: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.summaries) { summary in
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.component.title).font(.caption).bold().foregroundStyle(.secondary)
                    ForEach(store.readings(for: summary.component)) { sensorRow($0) }
                }
            }
        }
    }

    private func sensorRow(_ reading: Reading) -> some View {
        HStack {
            Text(reading.name).font(.caption)
            Text(reading.raw).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Text(Temperature.format(reading.celsius, fahrenheit: fahrenheit))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Temperature.color(for: reading.celsius))
        }
    }
}
