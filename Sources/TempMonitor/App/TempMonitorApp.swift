import SwiftUI

@main
struct TempMonitorApp: App {
    @StateObject private var store = MonitorStore()
    @AppStorage(SettingsKey.useFahrenheit) private var useFahrenheit = false
    @AppStorage(SettingsKey.menuBarMode) private var menuBarMode: MenuBarMode = .cpuGpu

    var body: some Scene {
        MenuBarExtra {
            PopupView(store: store)
        } label: {
            Text(menuBarMode.text(for: store.summaries, fahrenheit: useFahrenheit))
        }
        .menuBarExtraStyle(.window)
    }
}
