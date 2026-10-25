import SwiftUI

/// The System tab: fans, power, usage, memory, thermal state and battery.
struct SystemView: View {
    @ObservedObject var store: MonitorStore
    let fahrenheit: Bool
    let onSelect: (Metric) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ThermalBadge(state: store.thermalState)
                if !store.fans.isEmpty { fansSection }
                if let power = store.power { powerSection(power) }
                if let usage = store.usage { usageSection(usage) }
                if let memory = store.memory { memorySection(memory) }
                if let battery = store.battery { batterySection(battery) }
            }
        }
        .frame(maxHeight: 480)
    }

    // MARK: - Sections

    private var fansSection: some View {
        section("Fans") {
            ForEach(store.fans) { fan in
                row(.fan(fan.index), fan.rpm, String(format: "%.0f–%.0f rpm", fan.min, fan.max)) {
                    ProgressView(value: fan.fraction).progressViewStyle(.linear).controlSize(.small).frame(width: 110)
                }
            }
        }
    }

    private func powerSection(_ power: PowerReading) -> some View {
        section("Power") {
            if let system = power.system { row(.systemPower, system, "Whole machine") }
            row(.cpuPower, power.cpu)
            row(.gpuPower, power.gpu)
            row(.anePower, power.ane)
            row(.dramPower, power.dram)
        }
    }

    private func usageSection(_ usage: UsageReading) -> some View {
        section("Usage") {
            row(.cpuUsage, usage.cpu,
                String(format: "Performance %.0f%% · Efficiency %.0f%%", usage.performanceCores, usage.efficiencyCores))
            if let gpu = usage.gpu { row(.gpuUsage, gpu) }
        }
    }

    private func memorySection(_ memory: MemoryReading) -> some View {
        section("Memory") {
            row(.memoryUsed, memory.usedGigabytes,
                String(format: "of %.0f GB · pressure %.0f%% · swap %.1f GB",
                       memory.totalGigabytes, memory.pressure, memory.swapGigabytes))
        }
    }

    private func batterySection(_ battery: BatteryReading) -> some View {
        section("Battery") {
            row(.batteryCharge, battery.charge, battery.statusText)
            row(.batteryPower, battery.watts, battery.flowText)
            HStack(spacing: 14) {
                if let health = battery.health { info("Health", MetricUnit.percent.format(health)) }
                if let cycles = battery.cycleCount { info("Cycles", "\(cycles)") }
                if let adapter = battery.adapterWatts { info("Charger", String(format: "%.0f W", adapter)) }
            }
            .padding(.horizontal, 6)
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title).padding(.horizontal, 6)
            content()
        }
    }

    private func row(_ metric: Metric, _ value: Double, _ subtitle: String? = nil) -> some View {
        row(metric, value, subtitle) { EmptyView() }
    }

    private func row<A: View>(_ metric: Metric, _ value: Double, _ subtitle: String?,
                              @ViewBuilder accessory: @escaping () -> A) -> some View {
        MetricRow(metric: metric, value: value, subtitle: subtitle, history: store.lastHour(of: metric),
                  fahrenheit: fahrenheit, action: { onSelect(metric) }, accessory: accessory)
    }

    private func info(_ title: String, _ value: String) -> some View {
        StatView(title: title, value: value, valueFont: .system(.caption, design: .monospaced))
    }
}

/// Shows macOS's thermal state and whether it may be throttling.
private struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
            Text("Thermal state")
            Spacer()
            Text(state.title).bold()
            Text(state.mayBeThrottling ? "· may be throttling" : "· not throttling").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
        .foregroundStyle(state.mayBeThrottling ? color : .primary)
    }

    private var color: Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        default: return .red
        }
    }
}
