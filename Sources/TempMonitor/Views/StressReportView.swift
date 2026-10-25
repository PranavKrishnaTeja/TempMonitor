import SwiftUI
import Charts

/// Full results of one stress run.
struct StressReportView: View {
    let report: StressReport
    let fahrenheit: Bool
    let onBack: () -> Void

    /// One line on a report chart.
    private struct Series {
        let name: String
        let color: Color
        let value: (StressReport.Sample) -> Double?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                stats

                Text("Sustained = score in the final minute vs. the first 30 s. Below ~90% means the chip throttled to stay cool.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                chart("Temperature", unit: .temperature, series: [
                    Series(name: "CPU", color: .accentColor) { $0.cpuTemp },
                    Series(name: "GPU", color: .purple) { $0.gpuTemp },
                ])
                chart("Fan speed", unit: .rpm, series: [Series(name: "Fan", color: .gray) { $0.fan }])
                chart("Performance (GFLOPS)", unit: .rpm, series: [
                    Series(name: "CPU", color: .accentColor) { [target = report.target] in target.loadsCPU ? $0.cpuGflops : nil },
                    Series(name: "GPU", color: .purple) { [target = report.target] in target.loadsGPU ? $0.gpuGflops : nil },
                ])
            }
        }
        .frame(maxHeight: 560)
    }

    @ViewBuilder private var header: some View {
        HStack {
            BackButton(action: onBack)
            Spacer()
            Text("\(report.target.rawValue) stress test").font(.headline)
            Spacer()
        }
        Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · \(DurationFormat.clock(report.seconds)) of \(DurationFormat.clock(report.plannedSeconds))")
            .font(.caption).foregroundStyle(.secondary)
        if let reason = report.endReason {
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                StatView(title: "Peak CPU", value: temp(report.peakCPUTemp), tint: report.peakCPUTemp.map(Temperature.color(for:)))
                StatView(title: "Avg CPU", value: temp(report.avgCPUTemp))
                StatView(title: "Thermal state", value: report.worstThermalState)
            }
            GridRow {
                StatView(title: "Peak GPU", value: temp(report.peakGPUTemp), tint: report.peakGPUTemp.map(Temperature.color(for:)))
                StatView(title: "Avg GPU", value: temp(report.avgGPUTemp))
                StatView(title: "Max fan", value: MetricUnit.rpm.format(report.peakFan))
            }
            GridRow {
                StatView(title: "Avg power", value: report.avgPower.map { MetricUnit.watts.format($0) })
                StatView(title: "Peak power", value: report.peakPower.map { MetricUnit.watts.format($0) })
                StatView(title: "Fans started", value: fanSpinUpText)
            }
            if let cpu = report.avgCPUGflops {
                scoreRow("CPU", score: cpu, sustained: report.sustained(\.cpuGflops))
            }
            if let gpu = report.avgGPUGflops {
                scoreRow("GPU", score: gpu, sustained: report.sustained(\.gpuGflops))
            }
        }
    }

    private func scoreRow(_ part: String, score: Double, sustained: Double?) -> some View {
        GridRow {
            StatView(title: "\(part) score", value: GFLOPS.format(score))
            StatView(title: "\(part) sustained", value: sustained.map { MetricUnit.percent.format($0) },
                     tint: sustained.map(Self.sustainedColor))
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    private var fanSpinUpText: String {
        switch report.fanSpinUp {
        case nil: return "Never"
        case 0?: return "Already on"
        case let seconds?: return DurationFormat.clock(seconds)
        }
    }

    private func temp(_ v: Double?) -> String? {
        v.map { Temperature.format($0, fahrenheit: fahrenheit) }
    }

    /// Green when performance held up, orange for mild throttling, red for heavy throttling.
    private static func sustainedColor(_ percent: Double) -> Color {
        percent >= 90 ? .green : percent >= 75 ? .orange : .red
    }

    private func chart(_ title: String, unit: MetricUnit, series: [Series]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            Chart {
                ForEach(series, id: \.name) { line in
                    ForEach(report.samples, id: \.t) { s in
                        if let v = line.value(s) {
                            LineMark(x: .value("Seconds", s.t), y: .value(line.name, unit.display(v, fahrenheit: fahrenheit)),
                                     series: .value("Series", line.name))
                                .foregroundStyle(line.color)
                        }
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: unit != .temperature))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let s = value.as(Double.self) { Text(DurationFormat.clock(s)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(unit.axisLabel(v)) } }
                }
            }
            .frame(height: 90)
        }
    }
}
