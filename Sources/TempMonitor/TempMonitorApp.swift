import SwiftUI
import Charts

struct ComponentSummary: Identifiable {
    let component: Component
    let hottest: Double
    let average: Double
    let sensorCount: Int
    var id: Component { component }
}

enum MenuBarMode: String, CaseIterable, Identifiable {
    case cpuGpu, cpu, hottest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuGpu: return "CPU + GPU"
        case .cpu: return "CPU only"
        case .hottest: return "Hottest part"
        }
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var readings: [Reading] = []
    @Published var summaries: [ComponentSummary] = []
    @Published var fans: [FanReading] = []
    @Published var power: PowerReading?
    @Published var usage: UsageReading?
    @Published var memory: MemoryReading?
    @Published var battery: BatteryReading?
    @Published var thermalState = ProcessInfo.processInfo.thermalState
    /// Latest value of every metric, keyed by `Metric.key`.
    @Published var latest: [String: Double] = [:]

    let history = HistoryStore()
    lazy var stress = StressTest(store: self)

    private let smc = SMC()
    private lazy var coreTemps = smc.flatMap(SMCTemperatures.init)
    private let powerReader = PowerReader()
    private let statsReader = SystemStatsReader()
    private var tick = 0
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stress.stop(reason: "App quit")
                self?.history.saveNow()
            }
        }
    }

    func refresh() {
        readings = SensorReader.readAll(coreReadings: coreTemps?.read() ?? [])
        let groups = Dictionary(grouping: readings, by: \.component)
        summaries = Component.allCases.compactMap { c in
            guard let items = groups[c], !items.isEmpty else { return nil }
            let temps = items.map(\.celsius)
            return ComponentSummary(component: c, hottest: temps.max()!,
                                    average: temps.reduce(0, +) / Double(temps.count), sensorCount: temps.count)
        }

        fans = smc.map(FanReader.read) ?? []
        if let p = powerReader?.read(smc: smc) { power = p }
        if let u = statsReader.readUsage() { usage = u }
        memory = statsReader.readMemory()
        thermalState = ProcessInfo.processInfo.thermalState
        // The battery registry entry is large and changes slowly.
        if tick % 5 == 0 { battery = BatteryReader.read() }
        tick += 1

        var avg: [String: Double] = [:]
        var max: [String: Double] = [:]
        func set(_ m: Metric, _ v: Double?) {
            guard let v else { return }
            avg[m.key] = v
            max[m.key] = v
        }
        for s in summaries {
            avg[s.component.rawValue] = s.average
            max[s.component.rawValue] = s.hottest
        }
        for f in fans { set(.fan(f.index), f.rpm) }
        set(.systemPower, power?.system)
        set(.cpuPower, power?.cpu)
        set(.gpuPower, power?.gpu)
        set(.anePower, power?.ane)
        set(.dramPower, power?.dram)
        set(.cpuUsage, usage?.cpu)
        set(.gpuUsage, usage?.gpu)
        set(.memoryUsed, memory.map { $0.used / 1e9 })
        set(.batteryCharge, battery?.charge)
        set(.batteryPower, battery?.watts)

        latest = max
        history.record(avg: avg, max: max, at: Date())
        stress.sample()
    }

    func summary(for c: Component) -> ComponentSummary? {
        summaries.first { $0.component == c }
    }

    func menuBarText(mode: MenuBarMode, fahrenheit: Bool) -> String {
        func part(_ s: ComponentSummary) -> String {
            "\(s.component.shortTitle) \(formatTemp(s.hottest, fahrenheit: fahrenheit, unit: false))"
        }
        switch mode {
        case .cpuGpu:
            let parts = [Component.cpu, .gpu].compactMap(summary(for:)).map(part)
            return parts.isEmpty ? "--" : parts.joined(separator: "  ")
        case .cpu:
            return summary(for: .cpu).map(part) ?? "--"
        case .hottest:
            return summaries.max { $0.hottest < $1.hottest }.map(part) ?? "--"
        }
    }
}

func toDisplay(_ c: Double, fahrenheit: Bool) -> Double {
    fahrenheit ? c * 9 / 5 + 32 : c
}

func formatTemp(_ c: Double, fahrenheit: Bool, unit: Bool = true) -> String {
    let value = String(format: "%.0f°", toDisplay(c, fahrenheit: fahrenheit))
    return unit ? value + (fahrenheit ? "F" : "C") : value
}

func temperatureColor(for c: Double) -> Color {
    switch c {
    case ..<60: return .green
    case ..<80: return .orange
    default: return .red
    }
}

enum PopupTab: String, CaseIterable, Identifiable {
    case temps = "Temps", system = "System", stress = "Stress"
    var id: String { rawValue }
}

struct TempView: View {
    @ObservedObject var store: MonitorStore
    @AppStorage("useFahrenheit") private var useFahrenheit = false
    @AppStorage("menuBarMode") private var menuBarMode: MenuBarMode = .cpuGpu
    @State private var tab: PopupTab = .temps
    @State private var selected: Metric?
    @State private var selectedReport: StressReport?
    @State private var showAllSensors = false

    var body: some View {
        Group {
            if let m = selected {
                DetailView(store: store, metric: m) { selected = nil }
            } else if let r = selectedReport {
                StressReportView(report: r, fahrenheit: useFahrenheit) { selectedReport = nil }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("", selection: $tab) {
                            ForEach(PopupTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Picker("", selection: $useFahrenheit) {
                            Text("°C").tag(false)
                            Text("°F").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 80)
                    }

                    switch tab {
                    case .temps: temps
                    case .system: SystemView(store: store, fahrenheit: useFahrenheit) { selected = $0 }
                    case .stress: StressView(stress: store.stress, store: store, fahrenheit: useFahrenheit) { selectedReport = $0 }
                    }

                    Divider()
                    HStack {
                        Picker("Menu bar", selection: $menuBarMode) {
                            ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                        .font(.caption)
                        Spacer()
                        Button("Quit") { NSApplication.shared.terminate(nil) }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    @ViewBuilder private var temps: some View {
        if store.summaries.isEmpty {
            Text("No sensors found.").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 2) {
                ForEach(store.summaries) { s in
                    MetricRow(metric: .temperature(s.component), value: s.hottest,
                              subtitle: "avg \(formatTemp(s.average, fahrenheit: useFahrenheit)) · \(s.sensorCount) sensor\(s.sensorCount == 1 ? "" : "s")",
                              store: store, fahrenheit: useFahrenheit) { selected = .temperature(s.component) }
                }
            }
            Text("Click a component to see its history.").font(.caption2).foregroundStyle(.secondary)

            DisclosureGroup("All sensors (\(store.readings.count))", isExpanded: $showAllSensors) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.summaries) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.component.title).font(.caption).bold().foregroundStyle(.secondary)
                                ForEach(store.readings.filter { $0.component == s.component }) { r in
                                    HStack {
                                        Text(r.name).font(.caption)
                                        Text(r.raw).font(.caption2).foregroundStyle(.tertiary)
                                        Spacer()
                                        Text(formatTemp(r.celsius, fahrenheit: useFahrenheit))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(temperatureColor(for: r.celsius))
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            .font(.caption)
        }
    }
}

/// A clickable row: icon, title and subtitle, last-hour sparkline, current value.
struct MetricRow<Accessory: View>: View {
    let metric: Metric
    let value: Double?
    let subtitle: String?
    let store: MonitorStore
    let fahrenheit: Bool
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: metric.symbol)
                    .frame(width: 22)
                    .foregroundStyle(value.map { metric.tint(for: $0) } ?? .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title).font(.body)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    accessory()
                }
                Spacer()
                Sparkline(points: store.history.series(key: metric.key, range: .hour))
                    .frame(width: 70, height: 22)
                Text(value.map { metric.unit.format($0, fahrenheit: fahrenheit) } ?? "--")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(value.map { metric.tint(for: $0) } ?? .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 52, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension MetricRow where Accessory == EmptyView {
    init(metric: Metric, value: Double?, subtitle: String?, store: MonitorStore, fahrenheit: Bool, action: @escaping () -> Void) {
        self.init(metric: metric, value: value, subtitle: subtitle, store: store, fahrenheit: fahrenheit, action: action) { EmptyView() }
    }
}

struct Sparkline: View {
    let points: [HistoryPoint]

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Time", p.t), y: .value("Value", p.max), series: .value("Segment", p.segment))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .foregroundStyle(Color.accentColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(.hidden)
    }
}

@main
struct TempMonitorApp: App {
    @StateObject private var store = MonitorStore()
    @AppStorage("useFahrenheit") private var useFahrenheit = false
    @AppStorage("menuBarMode") private var menuBarMode: MenuBarMode = .cpuGpu

    var body: some Scene {
        MenuBarExtra {
            TempView(store: store)
        } label: {
            Text(store.menuBarText(mode: menuBarMode, fahrenheit: useFahrenheit))
        }
        .menuBarExtraStyle(.window)
    }
}
