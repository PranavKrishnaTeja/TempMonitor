import SwiftUI

/// Converting, formatting and color-coding temperatures, which are always stored in °C.
enum Temperature {
    static let warmThreshold = 60.0
    static let hotThreshold = 80.0

    static func display(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// e.g. "58°C", or "58°" when `showUnit` is false.
    static func format(_ celsius: Double, fahrenheit: Bool, showUnit: Bool = true) -> String {
        let value = String(format: "%.0f°", display(celsius, fahrenheit: fahrenheit))
        return showUnit ? value + (fahrenheit ? "F" : "C") : value
    }

    static func color(for celsius: Double) -> Color {
        switch celsius {
        case ..<warmThreshold: return .green
        case ..<hotThreshold: return .orange
        default: return .red
        }
    }
}

enum DurationFormat {
    /// Formats seconds as m:ss.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Array where Element == Double {
    /// Arithmetic mean, or nil for an empty array.
    var mean: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

extension ArraySlice where Element == Double {
    var mean: Double? { Array(self).mean }
}

/// `UserDefaults` keys shared by several views.
enum SettingsKey {
    static let useFahrenheit = "useFahrenheit"
    static let menuBarMode = "menuBarMode"
    static let stressTarget = "stressTarget"
    static let stressMinutes = "stressMinutes"
}
