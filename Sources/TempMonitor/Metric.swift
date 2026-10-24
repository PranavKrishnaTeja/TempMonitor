import SwiftUI

enum MetricUnit {
    case temperature, rpm, watts, percent, gigabytes

    /// Converts a stored value to what charts plot (only temperature depends on °C/°F).
    func display(_ v: Double, fahrenheit: Bool) -> Double {
        self == .temperature ? toDisplay(v, fahrenheit: fahrenheit) : v
    }

    func format(_ v: Double, fahrenheit: Bool) -> String {
        switch self {
        case .temperature: return formatTemp(v, fahrenheit: fahrenheit)
        case .rpm: return v < 1 ? "Off" : String(format: "%.0f rpm", v)
        case .watts: return String(format: abs(v) < 10 ? "%.1f W" : "%.0f W", v)
        case .percent: return String(format: "%.0f%%", v)
        case .gigabytes: return String(format: "%.1f GB", v)
        }
    }

    func axisLabel(_ v: Double) -> String {
        let n = v.formatted(.number.precision(.fractionLength(0...1)))
        switch self {
        case .temperature: return n + "°"
        case .rpm: return n
        case .watts: return n + "W"
        case .percent: return n + "%"
        case .gigabytes: return n + "G"
        }
    }

    /// Whether the chart's Y axis should start at zero.
    var includesZero: Bool { self == .rpm || self == .percent }
}

/// Describes one graphable value. `key` is its key in `HistoryStore` and `MonitorStore.latest`.
struct Metric: Hashable, Identifiable {
    let key: String
    let title: String
    let symbol: String
    let unit: MetricUnit
    /// Label for the dashed line: per-minute peak, or hottest sensor for temperatures.
    var peakLabel = "Peak"
    var warn: Double?
    var hot: Double?

    var id: String { key }

    func tint(for v: Double) -> Color {
        if unit == .temperature { return temperatureColor(for: v) }
        guard let warn, let hot else { return .primary }
        return v < warn ? .green : v < hot ? .orange : .red
    }

    static func temperature(_ c: Component) -> Metric {
        Metric(key: c.rawValue, title: c.title, symbol: c.symbol, unit: .temperature, peakLabel: "Hottest sensor")
    }

    static func fan(_ index: Int) -> Metric {
        Metric(key: "fan\(index)", title: "Fan \(index + 1)", symbol: "fanblades", unit: .rpm)
    }

    static let systemPower = Metric(key: "power.system", title: "System", symbol: "bolt.fill", unit: .watts)
    static let cpuPower = Metric(key: "power.cpu", title: "CPU", symbol: "cpu", unit: .watts)
    static let gpuPower = Metric(key: "power.gpu", title: "GPU", symbol: "square.stack.3d.up", unit: .watts)
    static let anePower = Metric(key: "power.ane", title: "Neural Engine", symbol: "brain", unit: .watts)
    static let dramPower = Metric(key: "power.dram", title: "Memory", symbol: "memorychip", unit: .watts)
    static let cpuUsage = Metric(key: "usage.cpu", title: "CPU", symbol: "speedometer", unit: .percent, warn: 60, hot: 85)
    static let gpuUsage = Metric(key: "usage.gpu", title: "GPU", symbol: "square.stack.3d.up", unit: .percent, warn: 60, hot: 85)
    static let memoryUsed = Metric(key: "mem.used", title: "Memory used", symbol: "memorychip", unit: .gigabytes)
    static let batteryCharge = Metric(key: "battery.charge", title: "Charge", symbol: "battery.75", unit: .percent)
    static let batteryPower = Metric(key: "battery.watts", title: "Battery power", symbol: "bolt.batteryblock", unit: .watts)
}
