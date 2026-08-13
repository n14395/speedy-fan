import Foundation

// Temperature display. Everything internal — thresholds, settings keys,
// supervision math — stays Celsius; conversion happens only where a number
// meets the screen.

/// How temperatures are shown. Stored as the rawValue in UserDefaults.
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case system
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System setting"
        case .celsius: return "Celsius (°C)"
        case .fahrenheit: return "Fahrenheit (°F)"
        }
    }
}

enum Temperature {
    nonisolated static func toFahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    /// Resolve a stored unit choice to "display Fahrenheit?". The system case
    /// follows the locale's temperature unit rather than its general
    /// measurement system — the UK is metric but reads weather in °C, the US
    /// in °F, and Foundation knows the difference.
    nonisolated static func usesFahrenheit(setting raw: String,
                                           locale: Locale = .current) -> Bool {
        switch TemperatureUnit(rawValue: raw) ?? .system {
        case .celsius: return false
        case .fahrenheit: return true
        case .system: return UnitTemperature(forLocale: locale) == .fahrenheit
        }
    }

    /// The current setting's answer, for call sites outside SwiftUI. Views
    /// should instead read the setting via @AppStorage and pass it in, so
    /// they re-render when it changes.
    static var usesFahrenheit: Bool {
        usesFahrenheit(setting: AppSettings.temperatureUnitRaw)
    }

    /// "95 °C" / "203 °F"
    nonisolated static func format(_ celsius: Double, fahrenheit: Bool) -> String {
        fahrenheit
            ? "\(Int(toFahrenheit(celsius).rounded())) °F"
            : "\(Int(celsius.rounded())) °C"
    }

    /// "95°" / "203°" — for the menu bar, where width is precious.
    nonisolated static func formatBare(_ celsius: Double, fahrenheit: Bool) -> String {
        fahrenheit
            ? "\(Int(toFahrenheit(celsius).rounded()))°"
            : "\(Int(celsius.rounded()))°"
    }

    /// A temperature *difference*: 10 °C of change is 18 °F of change, not
    /// 50 °F — deltas convert by scale alone, without the 32° offset.
    nonisolated static func formatDelta(_ celsius: Int, fahrenheit: Bool) -> String {
        fahrenheit
            ? "\(Int((Double(celsius) * 9 / 5).rounded())) °F"
            : "\(celsius) °C"
    }

    /// "70–80 °C" / "158–176 °F"
    nonisolated static func formatRange(_ lo: Int, _ hi: Int, fahrenheit: Bool) -> String {
        fahrenheit
            ? "\(Int(toFahrenheit(Double(lo)).rounded()))–\(Int(toFahrenheit(Double(hi)).rounded())) °F"
            : "\(lo)–\(hi) °C"
    }
}
