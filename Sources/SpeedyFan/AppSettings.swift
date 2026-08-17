import Foundation
import ServiceManagement

// Central home for UserDefaults keys and small app-level settings helpers.

enum SettingsKey {
    static let menuBarItems = "menuBarItems"
    static let linkFans = "linkFans"
    static let autoRevertMinutes = "autoRevertMinutes"
    static let menuBarIconVisible = "menuBarIconVisible"
    static let refreshSeconds = "refreshSeconds"
    static let failsafeTemp = "failsafeTemp"
    static let maxFansAtTemp = "maxFansAtTemp"
    static let temperatureUnit = "temperatureUnit"
    static let sensorsExpanded = "sensorsExpanded"
    static let settingsTab = "settingsTab"
    static let notifyFailsafe = "notifyFailsafe"
    static let notifyStuckFan = "notifyStuckFan"
    static let notifyBoost = "notifyBoost"
    static let notifyReturnToAuto = "notifyReturnToAuto"
    static let notificationSound = "notificationSound"

    /// Written by features that no longer exist ("Minimum fan speed") or that
    /// have been migrated to a new key ("menuBarDisplay" → `menuBarItems`).
    /// Cleared at launch so old values don't linger in preferences forever.
    static let retired = ["fanFloorPercent", "factoryFanMins", "fanMinWritable",
                          "menuBarDisplay"]
}

enum AppSettings {
    /// One slider drives all fans proportionally. Defaults to on.
    static var linkFans: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.linkFans) as? Bool ?? true
    }

    /// Minutes after which manual mode reverts to automatic; 0 = never.
    static var autoRevertMinutes: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.autoRevertMinutes)
    }

    // MARK: - Menu bar contents

    // Stored as a comma-joined list of raw values so @AppStorage can observe
    // it directly. An *empty* string means "show nothing", which is a real
    // setting (the menu bar item is removed); a *missing* key means "never
    // configured" and falls back to the default.
    static let defaultMenuBarItemsRaw = MenuBarItem.icon.rawValue

    static func menuBarItems(from raw: String) -> Set<MenuBarItem> {
        Set(raw.split(separator: ",").compactMap { MenuBarItem(rawValue: String($0)) })
    }

    static var menuBarItems: Set<MenuBarItem> {
        get {
            guard let raw = UserDefaults.standard.string(forKey: SettingsKey.menuBarItems)
            else { return menuBarItems(from: defaultMenuBarItemsRaw) }
            return menuBarItems(from: raw)
        }
        set {
            let raw = MenuBarItem.allCases.filter(newValue.contains)
                .map(\.rawValue).joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: SettingsKey.menuBarItems)
            // The menu bar item exists exactly when it has something to show,
            // so hiding it and selecting nothing are the same state.
            UserDefaults.standard.set(!newValue.isEmpty,
                                      forKey: SettingsKey.menuBarIconVisible)
        }
    }

    /// True when at least one *reading* is selected — the only case where the
    /// menu bar needs the app to poll.
    static var menuBarShowsReading: Bool {
        menuBarItems.contains { $0.isReading }
    }

    /// One-time move from the old single-choice "menuBarDisplay" setting. The
    /// fan glyph was always drawn back then, so every old choice maps to the
    /// icon plus (for the non-icon choices) that one reading.
    static func migrateMenuBarDisplay() {
        guard UserDefaults.standard.string(forKey: SettingsKey.menuBarItems) == nil,
              let old = UserDefaults.standard.string(forKey: "menuBarDisplay")
        else { return }
        var items: Set<MenuBarItem> = [.icon]
        if let reading = MenuBarItem(rawValue: old), reading.isReading {
            items.insert(reading)
        }
        menuBarItems = items
    }

    /// Seconds between menu bar stat refreshes, clamped to 1...20. Applies
    /// only to the menu bar icon; the open popup always refreshes every
    /// second.
    static let refreshSecondsRange = 1...20
    static let refreshSecondsDefault = 2

    static var refreshSeconds: Int {
        let stored = UserDefaults.standard.object(forKey: SettingsKey.refreshSeconds)
            as? Int ?? refreshSecondsDefault
        return stored.clamped(to: refreshSecondsRange)
    }

    /// Hottest-sensor temperature (°C) at which the thermal failsafe forces
    /// every fan back to Auto. Clamped well below the 120° sensor
    /// plausibility ceiling so real readings can always reach it.
    static let failsafeTempRange = 80...105
    static let failsafeTempDefault = 95

    static var failsafeTemp: Int {
        let stored = UserDefaults.standard.object(forKey: SettingsKey.failsafeTemp)
            as? Int ?? failsafeTempDefault
        return stored.clamped(to: failsafeTempRange)
    }

    /// Hottest-sensor temperature at which every fan is driven to maximum
    /// (whatever mode it was in) until the sensor cools; 0 = off.
    static let maxFansAtTempRange = 80...105

    static var maxFansAtTemp: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.maxFansAtTemp)
        return stored == 0 ? 0 : stored.clamped(to: maxFansAtTempRange)
    }

    /// The stored temperature-unit choice; TemperatureUnit.init(rawValue:)
    /// treats anything unrecognized as .system.
    static var temperatureUnitRaw: String {
        UserDefaults.standard.string(forKey: SettingsKey.temperatureUnit)
            ?? TemperatureUnit.system.rawValue
    }

    /// Whether notification banners play the standard sound. Defaults to on.
    /// (Per-event switches live on `NotificationEvent`.)
    static var notificationSound: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notificationSound)
            as? Bool ?? true
    }

    /// Bring preferences up to date with the current feature set: migrate what
    /// moved, then drop what's left behind. Order matters — the migration
    /// reads a key the cleanup deletes.
    static func migrateSettings() {
        migrateMenuBarDisplay()
        for key in SettingsKey.retired {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

// Menu bar icon visibility lives in UserDefaults, NOT in FanController:
// binding MenuBarExtra(isInserted:) to an ObservableObject publishes during
// scene updates and spins the main thread in an infinite update loop.
// @AppStorage is the one binding source MenuBarExtra tolerates.
enum IconVisibility {
    static let key = SettingsKey.menuBarIconVisible

    /// Put the menu bar item back. Hiding is deselecting everything, so
    /// restoring has to reselect something — the bare glyph, the smallest
    /// visible state. Called at launch and whenever the app is reopened, so
    /// hiding can never lock you out of the UI.
    static func show() {
        if AppSettings.menuBarItems.isEmpty {
            AppSettings.menuBarItems = [.icon]
        } else {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
