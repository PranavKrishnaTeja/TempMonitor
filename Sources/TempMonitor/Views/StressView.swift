import SwiftUI

/// The Stress tab: start a run, watch it live, and browse past reports.
struct StressView: View {
    @ObservedObject var stress: StressTest
    @ObservedObject var store: MonitorStore
    let fahrenheit: Bool
    let onSelect: (StressReport) -> Void

    @AppStorage(SettingsKey.stressTarget) private var target: StressTarget = .both
    @AppStorage(SettingsKey.stressMinutes) private var minutes = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let run = stress.live {
                running(run)
            } else {
                setup
            }
            if !stress.reports.isEmpty {
                Divider()
                pastRuns
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thermal stress test").font(.headline)
            Picker("Load", selection: $target) {
                ForEach(StressTarget.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Duration", selection: $minutes) {
                ForEach(StressTest.durationChoices, id: \.self) { Text("\($0) min").tag($0) }
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
                Text("\(DurationFormat.clock(run.elapsed)) / \(DurationFormat.clock(run.duration))")
                    .font(.system(.body, design: .monospaced))
            }
            ProgressView(value: min(run.elapsed / run.duration, 1))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    StatView(title: "CPU temp", value: temperature(of: .cpu))
                    StatView(title: "GPU temp", value: temperature(of: .gpu))
                    StatView(title: "Fan", value: store.fastestFanRPM.map { MetricUnit.rpm.format($0) })
                }
                GridRow {
                    StatView(title: "Power", value: store.power.map { MetricUnit.watts.format($0.bestSystemEstimate) })
                    StatView(title: "CPU score", value: run.target.loadsCPU ? GFLOPS.format(run.cpuGflops) : nil)
                    StatView(title: "GPU score", value: run.target.loadsGPU ? GFLOPS.format(run.gpuGflops) : nil)
                }
            }

            Button(role: .destructive) {
                stress.stop(.stoppedByUser)
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private var pastRuns: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Past runs")
                Spacer()
                Button("Clear") { stress.clearReports() }.buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(stress.reports) { report in
                        ReportRow(report: report, fahrenheit: fahrenheit) { onSelect(report) }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func temperature(of component: Component) -> String? {
        store.summary(for: component).map { Temperature.format($0.hottest, fahrenheit: fahrenheit) }
    }
}

enum GFLOPS {
    static func format(_ value: Double) -> String { String(format: "%.0f GFLOPS", value) }
}

private struct ReportRow: View {
    let report: StressReport
    let fahrenheit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(report.target.rawValue) · \(DurationFormat.clock(report.seconds))").font(.callout)
                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                if report.endReason != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Spacer()
                if let peak = report.peakCPUTemp ?? report.peakGPUTemp {
                    Text(Temperature.format(peak, fahrenheit: fahrenheit))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Temperature.color(for: peak))
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(HoverRowStyle(verticalPadding: 4))
    }
}
