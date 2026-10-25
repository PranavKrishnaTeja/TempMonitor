import Foundation

/// The hardware part a sensor belongs to. Declaration order is display order.
enum Component: String, CaseIterable, Identifiable, Comparable {
    case cpu, gpu, ssd, battery, board, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .battery: return "Battery"
        case .board: return "Power & Board"
        case .other: return "Other"
        }
    }

    /// Compact label used in the menu bar.
    var shortTitle: String {
        switch self {
        case .battery: return "BAT"
        case .board: return "PWR"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .ssd: return "internaldrive"
        case .battery: return "battery.75"
        case .board: return "bolt"
        case .other: return "thermometer"
        }
    }

    private var displayIndex: Int { Self.allCases.firstIndex(of: self)! }

    static func < (lhs: Component, rhs: Component) -> Bool { lhs.displayIndex < rhs.displayIndex }
}

/// One temperature sensor's current value.
struct Reading: Identifiable, Equatable {
    /// Raw sensor name, disambiguated when several sensors share it.
    let id: String
    /// Raw Apple sensor name.
    let raw: String
    /// Friendly name.
    let name: String
    let component: Component
    let celsius: Double

    /// Values outside this range come from disconnected or faulty sensors.
    static func isPlausible(_ celsius: Double) -> Bool { celsius > 0 && celsius < 150 }

    /// Sorts by component display order, then by name.
    static func displayOrder(_ a: Reading, _ b: Reading) -> Bool {
        if a.component != b.component { return a.component < b.component }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Hottest and average temperature of one component.
struct ComponentSummary: Identifiable, Equatable {
    let component: Component
    let hottest: Double
    let average: Double
    let sensorCount: Int
    var id: Component { component }

    /// One summary per component that has readings, in display order.
    static func summarize(_ readings: [Reading]) -> [ComponentSummary] {
        let groups = Dictionary(grouping: readings, by: \.component)
        return Component.allCases.compactMap { component in
            let temps = groups[component]?.map(\.celsius) ?? []
            guard let hottest = temps.max(), let average = temps.mean else { return nil }
            return ComponentSummary(component: component, hottest: hottest, average: average, sensorCount: temps.count)
        }
    }
}

/// What the menu bar label shows.
enum MenuBarMode: String, CaseIterable, Identifiable {
    case cpuGpu, cpu, hottest

    static let placeholder = "--"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuGpu: return "CPU + GPU"
        case .cpu: return "CPU only"
        case .hottest: return "Hottest part"
        }
    }

    /// e.g. "CPU 58°  GPU 56°".
    func text(for summaries: [ComponentSummary], fahrenheit: Bool) -> String {
        func label(_ s: ComponentSummary) -> String {
            "\(s.component.shortTitle) \(Temperature.format(s.hottest, fahrenheit: fahrenheit, showUnit: false))"
        }
        let shown: [ComponentSummary]
        switch self {
        case .cpuGpu: shown = summaries.filter { $0.component == .cpu || $0.component == .gpu }
        case .cpu: shown = summaries.filter { $0.component == .cpu }
        case .hottest: shown = summaries.max { $0.hottest < $1.hottest }.map { [$0] } ?? []
        }
        return shown.isEmpty ? Self.placeholder : shown.map(label).joined(separator: "  ")
    }
}
