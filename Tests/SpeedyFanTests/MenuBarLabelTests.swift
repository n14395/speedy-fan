import XCTest
import SMCCore
@testable import SpeedyFan

/// The menu bar status text for each combination of selected items.
final class MenuBarLabelTests: XCTestCase {

    private func fan(id: Int = 0, actual: Double, max: Double = 6000) -> FanStatus {
        FanStatus(id: id, name: "Fan", actualRPM: actual, minRPM: 1000,
                  maxRPM: max, targetRPM: 0, manual: false)
    }

    private func text(_ items: MenuBarItem..., fans: [FanStatus] = [],
                      temp: Double? = nil, fahrenheit: Bool = false) -> String? {
        MenuBarLabel.statusText(items: Set(items), fans: fans,
                                hottestTemp: temp, fahrenheit: fahrenheit)
    }

    func testIconAloneShowsNoText() {
        XCTAssertNil(text(.icon, fans: [fan(actual: 3000)], temp: 80))
    }

    func testNoItemsShowsNoText() {
        XCTAssertNil(MenuBarLabel.statusText(items: [], fans: [fan(actual: 3000)],
                                             hottestTemp: 80, fahrenheit: false))
    }

    func testRPMShowsBusiestFan() {
        let fans = [fan(id: 0, actual: 1234.6), fan(id: 1, actual: 2999.2)]
        XCTAssertEqual(text(.rpm, fans: fans), "2999")
    }

    func testRPMNilWithNoFans() {
        XCTAssertNil(text(.rpm))
    }

    func testPercentUsesEachFansOwnMaximum() {
        // 3000/6000 = 50%, 2400/3000 = 80% -> busiest wins.
        let fans = [fan(id: 0, actual: 3000, max: 6000),
                    fan(id: 1, actual: 2400, max: 3000)]
        XCTAssertEqual(text(.percent, fans: fans), "80%")
    }

    func testPercentRoundsAndCapsAt100() {
        XCTAssertEqual(text(.percent, fans: [fan(actual: 3020, max: 6000)]), "50%")
        // Actual RPM can briefly overshoot the nominal maximum.
        XCTAssertEqual(text(.percent, fans: [fan(actual: 6500, max: 6000)]), "100%")
    }

    func testPercentSkipsFansWithZeroMaximum() {
        XCTAssertNil(text(.percent, fans: [fan(actual: 3000, max: 0)]))
    }

    func testTempFormatsRoundedDegrees() {
        XCTAssertEqual(text(.temp, temp: 61.6), "62°")
        XCTAssertEqual(text(.temp, temp: 39.2), "39°")
        XCTAssertNil(text(.temp, temp: nil))
    }

    func testTempHonorsTheDisplayUnit() {
        XCTAssertEqual(text(.temp, temp: 61.6, fahrenheit: true), "143°")
        // Only display converts: RPM and % are unit-less either way.
        XCTAssertEqual(text(.rpm, .temp, fans: [fan(actual: 3000)],
                            temp: 61.6, fahrenheit: true), "3000 · 143°")
    }

    func testSensorNameKnownKeysPrefixesAndFallback() {
        XCTAssertEqual(SensorName.label(for: "TC0P"), "CPU Proximity")
        XCTAssertEqual(SensorName.label(for: "TA0P"), "Ambient")
        XCTAssertEqual(SensorName.label(for: "Tp01"), "CPU (Tp01)")
        XCTAssertEqual(SensorName.label(for: "Tg0f"), "GPU (Tg0f)")
        XCTAssertEqual(SensorName.label(for: "TXYZ"), "TXYZ")
    }

    func testSelectedReadingsAreJoinedInDeclarationOrder() {
        let fans = [fan(actual: 3000, max: 6000)]
        // Selection order must not matter: the menu bar always reads
        // RPM, then %, then temperature.
        XCTAssertEqual(text(.temp, .rpm, .percent, fans: fans, temp: 61.6),
                       "3000 · 50% · 62°")
        XCTAssertEqual(text(.rpm, .temp, fans: fans, temp: 61.6), "3000 · 62°")
        // The icon contributes no text but doesn't suppress the readings.
        XCTAssertEqual(text(.icon, .rpm, fans: fans), "3000")
    }

    func testUnavailableReadingsAreSkippedNotBlank() {
        // No temperature sensor yet, but RPM is known.
        XCTAssertEqual(text(.rpm, .temp, fans: [fan(actual: 2000)], temp: nil),
                       "2000")
    }

    func testItemRawValuesAndTitlesAreStable() {
        // rawValues are persisted in preferences.
        XCTAssertEqual(MenuBarItem.allCases.map(\.rawValue),
                       ["icon", "rpm", "percent", "temp"])
        XCTAssertEqual(MenuBarItem.icon.title, "Fan icon")
        XCTAssertEqual(MenuBarItem.rpm.title, "Fan speed (RPM)")
        XCTAssertEqual(MenuBarItem.percent.title, "Fan speed (%)")
        XCTAssertEqual(MenuBarItem.temp.title, "Hottest temperature")
        XCTAssertEqual(MenuBarItem.rpm.id, "rpm")
    }

    func testOnlyTheIconIsNotAReading() {
        XCTAssertFalse(MenuBarItem.icon.isReading)
        for item in MenuBarItem.allCases where item != .icon {
            XCTAssertTrue(item.isReading, item.rawValue)
        }
    }
}
