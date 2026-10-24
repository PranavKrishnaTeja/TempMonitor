import SwiftUI
import Charts

/// The Stress tab: start a run, watch it live, and browse past reports.
struct StressView: View {
    @ObservedObject var stress: StressTest
    @ObservedObject var store: MonitorStore
    let fahrenheit: Bool
    let onSelect: (StressReport) -> Void

    @AppStorage("stressTarget") private var target: StressTest.Target = .both
    @AppStorage("stressMinutes") private var minutes = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let run = stress.live {
                running(run)
            } else {
                setup
            }

            if !stress.reports.isEmpty {
                Divider()
                HStack {
                    Text("Past runs").font(.subheadline).bold().foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { stress.clearReports() }.buttonStyle(.borderless).font(.caption)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(stress.reports) { r in ReportRow(report: r, fahrenheit: fahrenheit) { onSelect(r) } }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thermal stress test").font(.headline)
            Picker("Load", selection: $target) {
                ForEach(StressTest.Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Duration", selection: $minutes) {
                ForEach([1, 3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                stress.start(target: target, minutes: minutes)
            } label: {
                Label("Start", systemImage: "flame").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let error = stress.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Runs the chip at full load and records temperatures, fan speed, power and sustained performance. Stops automatically at \(Int(StressTest.abortTemperature)) °C or a critical thermal state. Plug in for repeatable results.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func running(_ run: StressTest.Live) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Running \(run.target.rawValue)").font(.headline)
                Spacer()
                Text("\(clock(run.elapsed)) / \(clock(run.duration))").font(.system(.body, design: .monospaced))
            }
            ProgressView(value: min(run.elapsed / run.duration, 1))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("CPU temp", store.summary(for: .cpu).map { formatTemp($0.hottest, fahrenheit: fahrenheit) })
                    stat("GPU temp", store.summary(for: .gpu).map { formatTemp($0.hottest, fahrenheit: fahrenheit) })
                    stat("Fan", store.fans.map(\.rpm).max().map { MetricUnit.rpm.format($0, fahrenheit: false) })
                }
                GridRow {
                    stat("Power", store.power.map { MetricUnit.watts.format($0.system ?? $0.cpu + $0.gpu, fahrenheit: false) })
                    stat("CPU score", run.target == .gpu ? nil : String(format: "%.0f GFLOPS", run.cpuGflops))
                    stat("GPU score", run.target == .cpu ? nil : String(format: "%.0f GFLOPS", run.gpuGflops))
                }
            }

            Button(role: .destructive) {
                stress.stop(reason: "Stopped by you")
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "--").font(.system(.callout, design: .monospaced))
        }
    }
}

private struct ReportRow: View {
    let report: StressReport
    let fahrenheit: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(report.target.rawValue) · \(clock(report.seconds))").font(.callout)
                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                if report.endReason != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Spacer()
                if let peak = report.peakCPUTemp ?? report.peakGPUTemp {
                    Text(formatTemp(peak, fahrenheit: fahrenheit))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(temperatureColor(for: peak))
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Full results of one stress run.
struct StressReportView: View {
    let report: StressReport
    let fahrenheit: Bool
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(action: onBack) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
                    Spacer()
                    Text("\(report.target.rawValue) stress test").font(.headline)
                    Spacer()
                }
                Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · \(clock(report.seconds)) of \(clock(report.plannedSeconds))")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = report.endReason {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        stat("Peak CPU", temp(report.peakCPUTemp), tint: report.peakCPUTemp.map(temperatureColor(for:)))
                        stat("Avg CPU", temp(report.avgCPUTemp))
                        stat("Thermal state", report.worstThermalState)
                    }
                    GridRow {
                        stat("Peak GPU", temp(report.peakGPUTemp), tint: report.peakGPUTemp.map(temperatureColor(for:)))
                        stat("Avg GPU", temp(report.avgGPUTemp))
                        stat("Max fan", MetricUnit.rpm.format(report.peakFan, fahrenheit: false))
                    }
                    GridRow {
                        stat("Avg power", report.avgPower.map { MetricUnit.watts.format($0, fahrenheit: false) })
                        stat("Peak power", report.peakPower.map { MetricUnit.watts.format($0, fahrenheit: false) })
                        stat("Fans started", fanSpinUpText)
                    }
                    if let cpu = report.avgCPUGflops {
                        GridRow {
                            stat("CPU score", String(format: "%.0f GFLOPS", cpu))
                            sustainedStat("CPU sustained", report.sustained(\.cpuGflops))
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                    if let gpu = report.avgGPUGflops {
                        GridRow {
                            stat("GPU score", String(format: "%.0f GFLOPS", gpu))
                            sustainedStat("GPU sustained", report.sustained(\.gpuGflops))
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }

                Text("Sustained = score in the final minute vs. the first 30 s. Below ~90% means the chip throttled to stay cool.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                chart("Temperature", unit: .temperature, series: [
                    ("CPU", Color.accentColor, { $0.cpuTemp }),
                    ("GPU", Color.purple, { $0.gpuTemp }),
                ])
                chart("Fan speed", unit: .rpm, series: [("Fan", Color.gray, { $0.fan })])
                chart("Performance (GFLOPS)", unit: .rpm, series: [
                    ("CPU", Color.accentColor, { report.target == .gpu ? nil : $0.cpuGflops }),
                    ("GPU", Color.purple, { report.target == .cpu ? nil : $0.gpuGflops }),
                ])
            }
        }
        .frame(maxHeight: 560)
    }

    private var fanSpinUpText: String {
        switch report.fanSpinUp {
        case nil: return "Never"
        case 0?: return "Already on"
        case let s?: return clock(s)
        }
    }

    private func temp(_ v: Double?) -> String? {
        v.map { formatTemp($0, fahrenheit: fahrenheit) }
    }

    private func stat(_ title: String, _ value: String?, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "--").font(.system(.callout, design: .monospaced)).foregroundStyle(tint ?? .primary)
        }
    }

    private func sustainedStat(_ title: String, _ v: Double?) -> some View {
        stat(title, v.map { String(format: "%.0f%%", $0) }, tint: v.map { $0 >= 90 ? .green : $0 >= 75 ? .orange : .red })
    }

    private func chart(_ title: String, unit: MetricUnit,
                       series: [(String, Color, (StressReport.Sample) -> Double?)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            Chart {
                ForEach(series, id: \.0) { name, color, value in
                    ForEach(report.samples, id: \.t) { s in
                        if let v = value(s) {
                            LineMark(x: .value("Seconds", s.t), y: .value(name, unit.display(v, fahrenheit: fahrenheit)),
                                     series: .value("Series", name))
                                .foregroundStyle(color)
                        }
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: unit != .temperature))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let s = value.as(Double.self) { Text(clock(s)) } }
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

/// Formats seconds as m:ss.
func clock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}
