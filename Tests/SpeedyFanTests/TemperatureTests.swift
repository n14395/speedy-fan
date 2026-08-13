import XCTest
@testable import SpeedyFan

/// Temperature display conversion. Everything internal stays Celsius; these
/// pin the display-side formatting for both units.
final class TemperatureTests: XCTestCase {

    func testConversion() {
        XCTAssertEqual(Temperature.toFahrenheit(0), 32)
        XCTAssertEqual(Temperature.toFahrenheit(100), 212)
        XCTAssertEqual(Temperature.toFahrenheit(95), 203)
    }

    func testFormat() {
        XCTAssertEqual(Temperature.format(95, fahrenheit: false), "95 °C")
        XCTAssertEqual(Temperature.format(95, fahrenheit: true), "203 °F")
        XCTAssertEqual(Temperature.format(61.6, fahrenheit: false), "62 °C")
        XCTAssertEqual(Temperature.format(61.6, fahrenheit: true), "143 °F")
    }

    func testFormatBare() {
        XCTAssertEqual(Temperature.formatBare(61.6, fahrenheit: false), "62°")
        XCTAssertEqual(Temperature.formatBare(61.6, fahrenheit: true), "143°")
    }

    func testDeltaConvertsByScaleAlone() {
        // 10 °C of *change* is 18 °F of change — no 32° offset.
        XCTAssertEqual(Temperature.formatDelta(10, fahrenheit: false), "10 °C")
        XCTAssertEqual(Temperature.formatDelta(10, fahrenheit: true), "18 °F")
        XCTAssertEqual(Temperature.formatDelta(5, fahrenheit: true), "9 °F")
    }

    func testFormatRange() {
        XCTAssertEqual(Temperature.formatRange(70, 80, fahrenheit: false), "70–80 °C")
        XCTAssertEqual(Temperature.formatRange(70, 80, fahrenheit: true), "158–176 °F")
    }

    func testOverridesBeatTheLocale() {
        XCTAssertTrue(Temperature.usesFahrenheit(
            setting: "fahrenheit", locale: Locale(identifier: "de_DE")))
        XCTAssertFalse(Temperature.usesFahrenheit(
            setting: "celsius", locale: Locale(identifier: "en_US")))
    }

    func testSystemSettingFollowsTheLocaleTemperatureUnit() {
        XCTAssertTrue(Temperature.usesFahrenheit(
            setting: "system", locale: Locale(identifier: "en_US")))
        XCTAssertFalse(Temperature.usesFahrenheit(
            setting: "system", locale: Locale(identifier: "de_DE")))
        // The UK is metric for temperature even though it pours pints.
        XCTAssertFalse(Temperature.usesFahrenheit(
            setting: "system", locale: Locale(identifier: "en_GB")))
    }

    func testGarbageSettingFallsBackToSystem() {
        XCTAssertTrue(Temperature.usesFahrenheit(
            setting: "kelvin", locale: Locale(identifier: "en_US")))
        XCTAssertFalse(Temperature.usesFahrenheit(
            setting: "kelvin", locale: Locale(identifier: "de_DE")))
    }

    func testUnitRawValuesAndTitlesAreStable() {
        // rawValues are persisted in preferences.
        XCTAssertEqual(TemperatureUnit.allCases.map(\.rawValue),
                       ["system", "celsius", "fahrenheit"])
        XCTAssertEqual(TemperatureUnit.system.title, "System setting")
        XCTAssertEqual(TemperatureUnit.celsius.title, "Celsius (°C)")
        XCTAssertEqual(TemperatureUnit.fahrenheit.title, "Fahrenheit (°F)")
    }
}
