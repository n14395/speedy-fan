import SwiftUI
import SMCCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.migrateSettings()
        // Hiding is session-only: every launch starts with the icon visible.
        IconVisibility.show()

        // Sleep stops every timer we have while leaving the SMC exactly as it
        // was, so fan state has to be handed over explicitly at both ends.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)

        // Test hook: hide the icon a few seconds after launch so the
        // hide/reopen cycle can be exercised without clicking the UI.
        // Test hook: open the settings window without clicking the menu bar.
        if ProcessInfo.processInfo.environment["SPEEDYFAN_TEST_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                SettingsWindow.show()
            }
        }

        // Test hook: macOS doesn't expose the MenuBarExtra panel to
        // accessibility or screenshots, so render the same view — same 320pt
        // width — in a plain window when its layout needs checking.
        if ProcessInfo.processInfo.environment["SPEEDYFAN_TEST_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                PanelPreviewWindow.show()
            }
        }

        // Test hook: drive the sleep/wake handlers directly, so the capture
        // and restore can be checked without actually sleeping the machine.
        if let pct = ProcessInfo.processInfo.environment["SPEEDYFAN_TEST_SLEEP"] {
            let fraction = Double(pct) ?? 0
            let controller = FanController.shared
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if fraction > 0 { controller.applyManualLinked(fraction: fraction) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                controller.prepareForSleep()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                controller.resumeAfterWake()
            }
        }

        if ProcessInfo.processInfo.environment["SPEEDYFAN_TEST_HIDE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                NSLog("SpeedyFan TEST: hiding menu bar icon")
                UserDefaults.standard.set(false, forKey: IconVisibility.key)
            }
        }
    }

    // AppKit posts both of these on the main thread, so they can call straight
    // into the controller. willSleep in particular must not defer its work.
    @objc private func systemWillSleep() {
        FanController.shared.prepareForSleep()
    }

    @objc private func systemDidWake() {
        FanController.shared.resumeAfterWake()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a fan pinned to a manual speed after the app is gone.
        FanController.shared.restoreAutoIfNeeded()
    }

    // `open SpeedyFan.app` while the app is already running lands here:
    // it is the way back after hiding the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        NSLog("SpeedyFan: reopen event, restoring menu bar icon")
        IconVisibility.show()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Belt and braces: any activation (Finder double-click, Dock, `open`)
        // restores the icon too — but not while the settings window is open.
        // The user isn't locked out there, and clicking back into that very
        // window would otherwise undo turning the menu bar item off.
        guard !SettingsWindow.isOpen else { return }
        if !IconVisibility.isVisible {
            NSLog("SpeedyFan: became active, restoring menu bar icon")
            IconVisibility.show()
        }
    }
}

// Debug-only host for MenuView, driven by SPEEDYFAN_TEST_PANEL.
@MainActor
enum PanelPreviewWindow {
    private static var controller: NSWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentViewController:
            NSHostingController(rootView: MenuView()))
        window.title = "SpeedyFan Panel (preview)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

// The things the menu bar item can show. Each is independently on or off, and
// the item displays whichever are on, in this order. Selecting none leaves
// nothing to draw, so the menu bar item is removed altogether — that is what
// "Hide menu bar icon" means.
enum MenuBarItem: String, CaseIterable, Identifiable {
    case icon
    case rpm
    case percent
    case temp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "Fan icon"
        case .rpm: return "Fan speed (RPM)"
        case .percent: return "Fan speed (%)"
        case .temp: return "Hottest temperature"
        }
    }

    /// A reading that has to be kept current, as opposed to the static glyph.
    /// Only these make the app poll for menu bar data.
    var isReading: Bool { self != .icon }
}

struct MenuBarLabel: View {
    @ObservedObject var controller = FanController.shared
    @AppStorage(SettingsKey.menuBarItems) private var itemsRaw = AppSettings.defaultMenuBarItemsRaw

    var body: some View {
        HStack(spacing: 3) {
            if AppSettings.menuBarItems(from: itemsRaw).contains(.icon) {
                Image(systemName: "fan.fill")
            }
            // Reads the controller's published stat rather than deriving one
            // from `fans`/`hottestTemp`: those change on every hardware poll,
            // which would make the menu bar update at the panel's or the
            // failsafe's cadence instead of the user's chosen interval.
            if let text = controller.menuBarStat {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SpeedyFan")
        .accessibilityValue(controller.menuBarStat ?? "")
    }

    /// The selected readings, in `MenuBarItem.allCases` order, joined for the
    /// menu bar. nil when no reading is selected — the icon alone, or nothing.
    /// The busiest fan is the interesting one, so RPM/% report the maximum
    /// across fans rather than an average.
    static func statusText(items: Set<MenuBarItem>, fans: [FanStatus],
                           hottestTemp: Double?, fahrenheit: Bool) -> String? {
        let parts = MenuBarItem.allCases
            .filter { items.contains($0) }
            .compactMap {
                reading($0, fans: fans, hottestTemp: hottestTemp,
                        fahrenheit: fahrenheit)
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func reading(_ item: MenuBarItem, fans: [FanStatus],
                                hottestTemp: Double?,
                                fahrenheit: Bool) -> String? {
        switch item {
        case .icon:
            return nil
        case .rpm:
            return fans.map(\.actualRPM).max().map { "\(Int($0))" }
        case .percent:
            return fans
                .compactMap { $0.maxRPM > 0 ? $0.actualRPM / $0.maxRPM : nil }
                .max()
                .map { "\(Int(min(100, ($0 * 100).rounded())))%" }
        case .temp:
            return hottestTemp.map {
                Temperature.formatBare($0, fahrenheit: fahrenheit)
            }
        }
    }
}

@main
struct SpeedyFanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(IconVisibility.key) private var iconVisible = true

    var body: some Scene {
        MenuBarExtra(isInserted: $iconVisible) {
            MenuView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
