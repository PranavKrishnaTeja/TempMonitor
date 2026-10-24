import SwiftUI

/// The System tab: fans, power, usage, memory, thermal state and battery.
struct SystemView: View {
    @ObservedObject var store: MonitorStore
    let fahrenheit: Bool
    let onSelect: (Metric) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                thermalBadge

                if !store.fans.isEmpty {
                    section("Fans") {
                        ForEach(store.fans) { f in
                            row(.fan(f.index), f.rpm, String(format: "%.0f–%.0f rpm", f.min, f.max)) {
                                ProgressView(value: f.fraction).progressViewStyle(.linear).controlSize(.small).frame(width: 110)
                            }
                        }
                    }
                }

                if let p = store.power {
                    section("Power") {
                        if let system = p.system { row(.systemPower, system, "Whole machine") }
                        row(.cpuPower, p.cpu, nil)
                        row(.gpuPower, p.gpu, nil)
                        row(.anePower, p.ane, nil)
                        row(.dramPower, p.dram, nil)
                    }
                }

                if let u = store.usage {
                    section("Usage") {
                        row(.cpuUsage, u.cpu, String(format: "Performance %.0f%% · Efficiency %.0f%%", u.performanceCores, u.efficiencyCores))
                        if let gpu = u.gpu { row(.gpuUsage, gpu, nil) }
                    }
                }

                if let m = store.memory {
                    section("Memory") {
                        row(.memoryUsed, m.used / 1e9,
                            String(format: "of %.0f GB · pressure %.0f%% · swap %.1f GB", m.total / 1e9, m.pressure, m.swapUsed / 1e9))
                    }
                }

                if let b = store.battery {
                    section("Battery") {
                        row(.batteryCharge, b.charge, batteryStatus(b))
                        row(.batteryPower, b.watts, b.watts >= 0 ? "Into battery" : "Out of battery")
                        HStack(spacing: 14) {
                            if let health = b.health { info("Health", String(format: "%.0f%%", health)) }
                            if let cycles = b.cycleCount { info("Cycles", "\(cycles)") }
                            if let adapter = b.adapterWatts { info("Charger", String(format: "%.0f W", adapter)) }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .frame(maxHeight: 480)
    }

    private var thermalBadge: some View {
        let state = store.thermalState
        let color: Color = switch state {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
        return HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
            Text("Thermal state")
            Spacer()
            Text(state.title).bold()
            Text(state == .nominal ? "· not throttling" : "· may be throttling").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
        .foregroundStyle(color == .green ? .primary : color)
    }

    private func batteryStatus(_ b: BatteryReading) -> String {
        let state = b.isCharging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery"
        guard let mins = b.minutesRemaining else { return state }
        return "\(state) · \(mins / 60)h \(mins % 60)m \(b.isCharging ? "to full" : "left")"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).bold().foregroundStyle(.secondary).padding(.horizontal, 6)
            content()
        }
    }

    private func row(_ metric: Metric, _ value: Double, _ subtitle: String?) -> some View {
        MetricRow(metric: metric, value: value, subtitle: subtitle, store: store, fahrenheit: fahrenheit) { onSelect(metric) }
    }

    private func row<A: View>(_ metric: Metric, _ value: Double, _ subtitle: String?, @ViewBuilder accessory: @escaping () -> A) -> some View {
        MetricRow(metric: metric, value: value, subtitle: subtitle, store: store, fahrenheit: fahrenheit,
                  action: { onSelect(metric) }, accessory: accessory)
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}
