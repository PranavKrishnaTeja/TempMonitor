import SwiftUI

enum PopupTab: String, CaseIterable, Identifiable {
    case temps = "Temps", system = "System", stress = "Stress"
    var id: String { rawValue }
}

/// The window that opens from the menu bar: tabs, or a detail page when something is selected.
struct PopupView: View {
    @ObservedObject var store: MonitorStore
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false
    @AppStorage(SettingsKey.menuBarMode) private var menuBarMode: MenuBarMode = .cpuGpu
    @State private var tab: PopupTab = .temps
    @State private var selectedMetric: Metric?
    @State private var selectedReport: StressReport?

    var body: some View {
        Group {
            if let metric = selectedMetric {
                DetailView(store: store, metric: metric) { selectedMetric = nil }
            } else if let report = selectedReport {
                StressReportView(report: report, fahrenheit: useFahrenheit) { selectedReport = nil }
            } else {
                tabs
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch tab {
            case .temps:
                TempsView(store: store, fahrenheit: useFahrenheit) { selectedMetric = $0 }
            case .system:
                SystemView(store: store, fahrenheit: useFahrenheit) { selectedMetric = $0 }
            case .stress:
                StressView(stress: store.stress, store: store, fahrenheit: useFahrenheit) { selectedReport = $0 }
            }

            Divider()
            footer
        }
    }

    private var header: some View {
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
    }

    private var footer: some View {
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
