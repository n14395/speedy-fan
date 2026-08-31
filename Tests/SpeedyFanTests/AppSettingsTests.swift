import XCTest
import AppKit
@testable import SpeedyFan

/// UserDefaults-backed settings. Each test starts from a clean slate and the
/// user's real values are restored afterwards.
final class AppSettingsTests: XCTestCase {
    private let keys = [
        SettingsKey.menuBarItems, SettingsKey.linkFans,
        SettingsKey.autoRevertMinutes, SettingsKey.menuBarIconVisible,
        SettingsKey.refreshSeconds, SettingsKey.failsafeTemp,
        SettingsKey.sensorsExpanded, SettingsKey.maxFansAtTemp,
        SettingsKey.settingsTab, SettingsKey.temperatureUnit,
        SettingsKey.notifyFailsafe, SettingsKey.notifyStuckFan,
        SettingsKey.notifyBoost, SettingsKey.notifyReturnToAuto,
        SettingsKey.notificationSound, SettingsKey.boostReleaseMargin,
    ] + SettingsKey.retired
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testSettingsKeysAreStable() {
        // These strings are persisted in user preferences; changing one
        // silently resets that setting for existing users.
        XCTAssertEqual(SettingsKey.menuBarItems, "menuBarItems")
        XCTAssertEqual(SettingsKey.linkFans, "linkFans")
        XCTAssertEqual(SettingsKey.autoRevertMinutes, "autoRevertMinutes")
        XCTAssertEqual(SettingsKey.menuBarIconVisible, "menuBarIconVisible")
        XCTAssertEqual(SettingsKey.refreshSeconds, "refreshSeconds")
        XCTAssertEqual(SettingsKey.failsafeTemp, "failsafeTemp")
        XCTAssertEqual(SettingsKey.sensorsExpanded, "sensorsExpanded")
        XCTAssertEqual(SettingsKey.maxFansAtTemp, "maxFansAtTemp")
        XCTAssertEqual(SettingsKey.settingsTab, "settingsTab")
        XCTAssertEqual(SettingsKey.temperatureUnit, "temperatureUnit")
        XCTAssertEqual(SettingsKey.notifyFailsafe, "notifyFailsafe")
        XCTAssertEqual(SettingsKey.notifyStuckFan, "notifyStuckFan")
        XCTAssertEqual(SettingsKey.notifyBoost, "notifyBoost")
        XCTAssertEqual(SettingsKey.notifyReturnToAuto, "notifyReturnToAuto")
        XCTAssertEqual(SettingsKey.notificationSound, "notificationSound")
    }

    func testSettingsTabRawValuesAreStable() {
        // Persisted as the last-opened settings tab.
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue),
                       ["general", "fans", "menuBar", "notifications"])
    }

    func testSettingsTabFirstIsTheLeadingTab() {
        XCTAssertEqual(SettingsTab.allCases.first, SettingsTab.first)
    }

    func testEveryTabHasATitleAndResolvableToolbarSymbol() {
        // The tab strip is an NSToolbar: an SF Symbol name that doesn't
        // resolve renders as a blank icon rather than failing loudly.
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, tab.rawValue)
            XCTAssertNotNil(
                NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil),
                "unresolvable SF Symbol \(tab.symbol) for \(tab.rawValue)")
        }
    }

    func testSettingsTabFallsBackForRetiredTabs() {
        // "safety" was folded into the Fans tab; a stored tag that matches no
        // tab would otherwise leave the TabView with nothing selected.
        XCTAssertEqual(SettingsTab.sanitized("safety"), .general)
        XCTAssertEqual(SettingsTab.sanitized(nil), .general)
        XCTAssertEqual(SettingsTab.sanitized("menuBar"), .menuBar)
    }

    func testRetiredSettingsAreForgotten() {
        for key in SettingsKey.retired {
            UserDefaults.standard.set(42, forKey: key)
        }
        AppSettings.migrateSettings()
        for key in SettingsKey.retired {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), key)
        }
    }

    func testRetiredKeysCoverTheRemovedAndMigratedSettings() {
        XCTAssertEqual(SettingsKey.retired,
                       ["fanFloorPercent", "factoryFanMins", "fanMinWritable",
                        "menuBarDisplay"])
    }

    // MARK: - Notifications

    func testNotificationEventKeysAreStableAndDistinct() {
        XCTAssertEqual(NotificationEvent.failsafe.settingsKey, "notifyFailsafe")
        XCTAssertEqual(NotificationEvent.stuckFan.settingsKey, "notifyStuckFan")
        XCTAssertEqual(NotificationEvent.boost.settingsKey, "notifyBoost")
        XCTAssertEqual(NotificationEvent.returnToAuto.settingsKey,
                       "notifyReturnToAuto")
        XCTAssertEqual(Set(NotificationEvent.allCases.map(\.settingsKey)).count,
                       NotificationEvent.allCases.count)
    }

    func testEveryNotificationEventDefaultsOnAndHonorsItsSwitch() {
        for event in NotificationEvent.allCases {
            XCTAssertTrue(event.enabled, "\(event.rawValue) should default on")
            UserDefaults.standard.set(false, forKey: event.settingsKey)
            XCTAssertFalse(event.enabled, event.rawValue)
            UserDefaults.standard.set(true, forKey: event.settingsKey)
            XCTAssertTrue(event.enabled, event.rawValue)
        }
    }

    func testOnlySafetyEventsFallBackToAModalAlert() {
        XCTAssertTrue(NotificationEvent.failsafe.important)
        XCTAssertTrue(NotificationEvent.stuckFan.important)
        XCTAssertFalse(NotificationEvent.boost.important)
        XCTAssertFalse(NotificationEvent.returnToAuto.important)
    }

    func testNotificationSoundDefaultsOn() {
        XCTAssertTrue(AppSettings.notificationSound)
        UserDefaults.standard.set(false, forKey: SettingsKey.notificationSound)
        XCTAssertFalse(AppSettings.notificationSound)
    }

    func testTemperatureUnitDefaultsToSystem() {
        XCTAssertEqual(AppSettings.temperatureUnitRaw,
                       TemperatureUnit.system.rawValue)
        UserDefaults.standard.set("fahrenheit",
                                  forKey: SettingsKey.temperatureUnit)
        XCTAssertEqual(AppSettings.temperatureUnitRaw, "fahrenheit")
    }

    func testMaxFansAtTempDefaultsToOffAndClamps() {
        XCTAssertEqual(AppSettings.maxFansAtTemp, 0)
        UserDefaults.standard.set(90, forKey: SettingsKey.maxFansAtTemp)
        XCTAssertEqual(AppSettings.maxFansAtTemp, 90)
        // 0 stays "off" rather than clamping up into the range.
        UserDefaults.standard.set(0, forKey: SettingsKey.maxFansAtTemp)
        XCTAssertEqual(AppSettings.maxFansAtTemp, 0)
        UserDefaults.standard.set(50, forKey: SettingsKey.maxFansAtTemp)
        XCTAssertEqual(AppSettings.maxFansAtTemp, 80)
        UserDefaults.standard.set(200, forKey: SettingsKey.maxFansAtTemp)
        XCTAssertEqual(AppSettings.maxFansAtTemp, 105)
    }

    func testFailsafeTempDefaultsAndClamps() {
        XCTAssertEqual(AppSettings.failsafeTemp, 95)
        UserDefaults.standard.set(90, forKey: SettingsKey.failsafeTemp)
        XCTAssertEqual(AppSettings.failsafeTemp, 90)
        UserDefaults.standard.set(50, forKey: SettingsKey.failsafeTemp)
        XCTAssertEqual(AppSettings.failsafeTemp, 80)
        UserDefaults.standard.set(200, forKey: SettingsKey.failsafeTemp)
        XCTAssertEqual(AppSettings.failsafeTemp, 105)
    }

    func testMenuBarItemsDefaultToTheIconAlone() {
        XCTAssertEqual(AppSettings.menuBarItems, [.icon])
    }

    func testMenuBarItemsRoundTripAndIgnoreGarbage() {
        AppSettings.menuBarItems = [.rpm, .temp]
        XCTAssertEqual(AppSettings.menuBarItems, [.rpm, .temp])
        UserDefaults.standard.set("rpm,nonsense,temp", forKey: SettingsKey.menuBarItems)
        XCTAssertEqual(AppSettings.menuBarItems, [.rpm, .temp])
    }

    func testEmptySelectionIsDistinctFromUnset() {
        // "" means the user turned everything off; a missing key means they
        // never chose, which falls back to the default.
        AppSettings.menuBarItems = []
        XCTAssertEqual(AppSettings.menuBarItems, [])
        UserDefaults.standard.removeObject(forKey: SettingsKey.menuBarItems)
        XCTAssertEqual(AppSettings.menuBarItems, [.icon])
    }

    func testVisibilityTracksWhetherAnythingIsSelected() {
        // Hiding the menu bar item and selecting nothing are one state.
        AppSettings.menuBarItems = [.temp]
        XCTAssertTrue(IconVisibility.isVisible)
        AppSettings.menuBarItems = []
        XCTAssertFalse(IconVisibility.isVisible)
        AppSettings.menuBarItems = [.icon]
        XCTAssertTrue(IconVisibility.isVisible)
    }

    func testShowRestoresTheIconFromAnEmptySelection() {
        AppSettings.menuBarItems = []
        IconVisibility.show()
        XCTAssertEqual(AppSettings.menuBarItems, [.icon])
        XCTAssertTrue(IconVisibility.isVisible)
    }

    func testShowLeavesAnExistingSelectionAlone() {
        AppSettings.menuBarItems = [.rpm, .temp]
        IconVisibility.show()
        XCTAssertEqual(AppSettings.menuBarItems, [.rpm, .temp])
    }

    func testMenuBarShowsReadingIgnoresTheBareIcon() {
        AppSettings.menuBarItems = [.icon]
        XCTAssertFalse(AppSettings.menuBarShowsReading)
        AppSettings.menuBarItems = []
        XCTAssertFalse(AppSettings.menuBarShowsReading)
        AppSettings.menuBarItems = [.icon, .percent]
        XCTAssertTrue(AppSettings.menuBarShowsReading)
    }

    func testMigrationFromTheOldSingleChoiceSetting() {
        // The fan glyph was always drawn, so an old reading choice becomes
        // the icon plus that reading.
        UserDefaults.standard.set("temp", forKey: "menuBarDisplay")
        AppSettings.migrateSettings()
        XCTAssertEqual(AppSettings.menuBarItems, [.icon, .temp])
        XCTAssertNil(UserDefaults.standard.object(forKey: "menuBarDisplay"))
    }

    func testMigrationOfIconOnlyKeepsJustTheIcon() {
        UserDefaults.standard.set("icon", forKey: "menuBarDisplay")
        AppSettings.migrateSettings()
        XCTAssertEqual(AppSettings.menuBarItems, [.icon])
    }

    func testMigrationDoesNotClobberAnAlreadyMigratedSelection() {
        AppSettings.menuBarItems = []
        UserDefaults.standard.set("rpm", forKey: "menuBarDisplay")
        AppSettings.migrateSettings()
        XCTAssertEqual(AppSettings.menuBarItems, [])
    }

    func testRefreshSecondsDefaultsToTwo() {
        XCTAssertEqual(AppSettings.refreshSeconds, 2)
    }

    func testRefreshSecondsRespectsStoredValue() {
        UserDefaults.standard.set(5, forKey: SettingsKey.refreshSeconds)
        XCTAssertEqual(AppSettings.refreshSeconds, 5)
    }

    func testRefreshSecondsClampsToRange() {
        UserDefaults.standard.set(0, forKey: SettingsKey.refreshSeconds)
        XCTAssertEqual(AppSettings.refreshSeconds, 1)
        UserDefaults.standard.set(-3, forKey: SettingsKey.refreshSeconds)
        XCTAssertEqual(AppSettings.refreshSeconds, 1)
        UserDefaults.standard.set(99, forKey: SettingsKey.refreshSeconds)
        XCTAssertEqual(AppSettings.refreshSeconds, 20)
    }

    func testLinkFansDefaultsToOn() {
        XCTAssertTrue(AppSettings.linkFans)
    }

    func testLinkFansRespectsStoredValue() {
        UserDefaults.standard.set(false, forKey: SettingsKey.linkFans)
        XCTAssertFalse(AppSettings.linkFans)
        UserDefaults.standard.set(true, forKey: SettingsKey.linkFans)
        XCTAssertTrue(AppSettings.linkFans)
    }

    func testAutoRevertDefaultsToNever() {
        XCTAssertEqual(AppSettings.autoRevertMinutes, 0)
    }

    func testAutoRevertRespectsStoredValue() {
        UserDefaults.standard.set(30, forKey: SettingsKey.autoRevertMinutes)
        XCTAssertEqual(AppSettings.autoRevertMinutes, 30)
    }

    func testIconVisibleByDefault() {
        XCTAssertTrue(IconVisibility.isVisible)
    }

    func testIconVisibilityShowAndHide() {
        UserDefaults.standard.set(false, forKey: IconVisibility.key)
        XCTAssertFalse(IconVisibility.isVisible)
        IconVisibility.show()
        XCTAssertTrue(IconVisibility.isVisible)
    }
}

final class BoostReleaseMarginTests: XCTestCase {
    private let key = SettingsKey.boostReleaseMargin
    private var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testDefaultsToTheHysteresisFloor() {
        XCTAssertEqual(AppSettings.boostReleaseMargin, 10)
        XCTAssertEqual(AppSettings.boostReleaseMarginRange.lowerBound, 10)
    }

    func testRoundTripsAndClamps() {
        UserDefaults.standard.set(20, forKey: key)
        XCTAssertEqual(AppSettings.boostReleaseMargin, 20)
        // Below the floor the boost would flap around one threshold again.
        UserDefaults.standard.set(2, forKey: key)
        XCTAssertEqual(AppSettings.boostReleaseMargin, 10)
        UserDefaults.standard.set(90, forKey: key)
        XCTAssertEqual(AppSettings.boostReleaseMargin, 25)
    }

    func testEveryMarginIsOfferedByTheFiveStepPicker() {
        // The picker strides by 5; the range has to land on a multiple.
        let range = AppSettings.boostReleaseMarginRange
        XCTAssertEqual((range.upperBound - range.lowerBound) % 5, 0)
    }
}

// MARK: - Helper freshness

final class HelperStalenessTests: XCTestCase {
    func testMatchingDigestsAreNotStale() {
        XCTAssertFalse(Helper.isStale(bundled: "abc", installed: "abc"))
    }

    func testDifferingDigestsAreStale() {
        XCTAssertTrue(Helper.isStale(bundled: "abc", installed: "def"))
    }

    func testAnUnreadableFileIsNeverReportedStale() {
        // "We can't tell" must not surface as "update available": the button
        // it would show costs an admin password and fixes nothing.
        XCTAssertFalse(Helper.isStale(bundled: nil, installed: "abc"))
        XCTAssertFalse(Helper.isStale(bundled: "abc", installed: nil))
        XCTAssertFalse(Helper.isStale(bundled: nil, installed: nil))
    }
}
