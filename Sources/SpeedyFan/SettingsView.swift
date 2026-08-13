import SwiftUI
import AppKit

// Standalone settings window. The menu bar panel is for at-a-glance status
// and quick fan changes; everything configurable lives here, where there is
// room to explain what each option actually does.
//
// Hosted in a window we own rather than a SwiftUI `Settings` scene: this is an
// LSUIElement app, so nothing opens the standard settings scene for us, and a
// window we own can be raised reliably from the menu bar panel.
//
// The tab strip is an NSTabViewController in `.toolbar` style, not a SwiftUI
// TabView. A SwiftUI TabView draws its own tab-bar background, which doesn't
// meet the titlebar cleanly in a plain window — you get a seam and the window
// looks banded. Toolbar style puts the tabs *in* the titlebar, which is what a
// Mac settings window does anyway, and it resizes the window to each tab's
// content for free.
@MainActor
enum SettingsWindow {
    private static var controller: NSWindowController?

    /// Whether the user currently has the settings window in front of them —
    /// i.e. whether they still have a way to change these settings.
    static var isOpen: Bool { controller?.window?.isVisible ?? false }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: SettingsTabController())
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Toolbar-style tabs, each hosting one SwiftUI settings pane.
@MainActor
final class SettingsTabController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(viewController: tab.paneController)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol,
                                 accessibilityDescription: nil)
            addTabViewItem(item)
        }
        // Reopening lands on the tab you were last using.
        selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(
            of: SettingsTab.sanitized(
                UserDefaults.standard.string(forKey: SettingsKey.settingsTab))) ?? 0
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let item else { return }
        if let raw = item.identifier as? String {
            UserDefaults.standard.set(raw, forKey: SettingsKey.settingsTab)
        }
        retitleWindow()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // didSelect fires before the window exists on first show.
        retitleWindow()
    }

    /// The window keeps one title rather than renaming itself per pane (left
    /// alone, a toolbar-style tab window reads "Untitled"). Deferred because
    /// AppKit resets the title after `didSelect` returns, undoing a
    /// synchronous assignment.
    private func retitleWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.title = "SpeedyFan Settings"
        }
    }
}

// Three tabs for nine settings: enough to separate app housekeeping from
// "what the fans do" from "what the menu bar shows", without scattering
// related options across tabs the user has to hunt through. Grouping *within*
// the Fans tab is done with section headers instead of another tab.
enum SettingsTab: String, CaseIterable {
    case general, fans, menuBar

    /// The tab a fresh install — or a stored tag that no longer matches any
    /// tab — lands on.
    static let first = SettingsTab.general

    static func sanitized(_ raw: String?) -> SettingsTab {
        SettingsTab(rawValue: raw ?? "") ?? first
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .fans: return "Fans"
        case .menuBar: return "Menu Bar"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .fans: return "fan.fill"
        case .menuBar: return "menubar.rectangle"
        }
    }

    /// Each pane states its own width and lets its Form size itself
    /// vertically. `sizingOptions` is what publishes that natural size as the
    /// controller's `preferredContentSize` — without it the tab controller has
    /// nothing to size the window from, and every pane gets a default-sized
    /// window that clips it.
    @MainActor
    var paneController: NSViewController {
        let controller: NSHostingController<AnyView>
        switch self {
        case .general: controller = NSHostingController(rootView: AnyView(GeneralSettingsTab().paneWidth()))
        case .fans: controller = NSHostingController(rootView: AnyView(FanSettingsTab().paneWidth()))
        case .menuBar: controller = NSHostingController(rootView: AnyView(MenuBarSettingsTab().paneWidth()))
        }
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }
}

private extension View {
    func paneWidth() -> some View { frame(width: 540) }
}

/// Explanatory text under a setting. Sized to wrap rather than truncate.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            // Grouped-form footers center by default; these read as prose.
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Fans

private struct FanSettingsTab: View {
    @ObservedObject private var controller = FanController.shared
    @AppStorage(SettingsKey.linkFans) private var linkFans = true
    @AppStorage(SettingsKey.autoRevertMinutes) private var autoRevertMinutes = 0
    @AppStorage(SettingsKey.failsafeTemp) private var failsafeTemp = AppSettings.failsafeTempDefault
    @AppStorage(SettingsKey.maxFansAtTemp) private var maxFansAtTemp = 0
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.system.rawValue

    private var useF: Bool { Temperature.usesFahrenheit(setting: temperatureUnitRaw) }

    var body: some View {
        Form {
            Section {
                Toggle("Link fans", isOn: $linkFans)
            } header: {
                Text("Manual control")
            } footer: {
                Note("One switch and one slider drive every fan. Turn off for separate per-fan controls.")
            }

            Section {
                Picker("Return to automatic after", selection: $autoRevertMinutes) {
                    Text("Never").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
            } footer: {
                Note("Fans you set by hand go back to automatic after this long.")
            }

            Section {
                Picker("Failsafe temperature", selection: $failsafeTemp) {
                    ForEach([85, 90, 95, 100], id: \.self) { temp in
                        Text(Temperature.format(Double(temp), fahrenheit: useF))
                            .tag(temp)
                    }
                }
            } header: {
                Text("Temperature protection")
            } footer: {
                Note("If a sensor reaches this while fans are set by hand, they all return to automatic.")
            }

            Section {
                Picker("Maximum fans at", selection: Binding(
                    get: { maxFansAtTemp },
                    set: { maxFansAtTemp = $0; controller.enforceMaxBoost() }
                )) {
                    Text("Off").tag(0)
                    ForEach([85, 90, 95, 100], id: \.self) { temp in
                        Text(Temperature.format(Double(temp), fahrenheit: useF))
                            .tag(temp)
                    }
                }
            } footer: {
                Note("""
                All fans go to full speed when a sensor reaches this — \
                overriding automatic and manual — until it cools \
                \(Temperature.formatDelta(FanController.boostReleaseMargin, fahrenheit: useF)) below.
                """)
            }

            Section {
                // The number most likely to be set wrongly is a threshold
                // chosen against a PC-shaped intuition about idle temps.
                Note("Apple silicon sensors read \(Temperature.formatRange(70, 80, fahrenheit: useF)) at idle; the panel's Sensors list shows what this Mac reports.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Menu bar

private struct MenuBarSettingsTab: View {
    // Bound to the raw string rather than read through AppSettings so the view
    // redraws when the set changes — including from IconVisibility.show().
    @AppStorage(SettingsKey.menuBarItems) private var itemsRaw = AppSettings.defaultMenuBarItemsRaw
    @AppStorage(SettingsKey.refreshSeconds) private var refreshSeconds = AppSettings.refreshSecondsDefault

    private var items: Set<MenuBarItem> { AppSettings.menuBarItems(from: itemsRaw) }
    private var showsReading: Bool { items.contains(where: \.isReading) }

    var body: some View {
        Form {
            Section {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.title, isOn: Binding(
                        get: { items.contains(item) },
                        set: { on in
                            var next = items
                            if on { next.insert(item) } else { next.remove(item) }
                            AppSettings.menuBarItems = next
                        }
                    ))
                }
                // Hiding *is* showing nothing, so this is the same setting
                // seen from the other side rather than a separate switch.
                Toggle("Hide menu bar icon", isOn: Binding(
                    get: { items.isEmpty },
                    set: { hide in
                        AppSettings.menuBarItems = hide ? [] : [.icon]
                    }
                ))
            } header: {
                Text("Menu bar shows")
            } footer: {
                Note("""
                Speed readings report the busiest fan. Turn everything off to \
                hide SpeedyFan from the menu bar — it keeps running, and the \
                icon comes back next launch so you can't lock yourself out.
                """)
            }

            Section {
                Picker("Update reading every", selection: $refreshSeconds) {
                    ForEach([1, 2, 3, 5, 10, 15, 20], id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(seconds) seconds")
                            .tag(seconds)
                    }
                }
                .disabled(!showsReading)
            } footer: {
                Note(showsReading
                     ? "Menu bar only; the open panel always updates every second."
                     : "Nothing to refresh — SpeedyFan stops polling while the panel is closed.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var controller = FanController.shared
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.system.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { enabled in
                        do { try LoginItem.setEnabled(enabled) } catch {
                            controller.lastError =
                                "Login item: \(error.localizedDescription)"
                        }
                    }
                ))
            } footer: {
                Note("The temperature protections only work while SpeedyFan runs.")
            }

            Section {
                Picker("Show temperatures in", selection: $temperatureUnitRaw) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
            } footer: {
                Note("""
                “System setting” follows your macOS region. Display only — \
                the protection thresholds don't move.
                """)
            }

            Section {
                LabeledContent("Helper tool") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(controller.helperInstalled ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(controller.helperInstalled ? "Installed" : "Not installed")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Uninstall Helper…") { confirmUninstallHelper() }
                    .disabled(!controller.helperInstalled)
            } footer: {
                Note("""
                Fan changes need admin rights, so SpeedyFan installs a small \
                helper once. Uninstalling returns fans to automatic.
                """)
            }

            Section {
                LabeledContent("SpeedyFan", value: versionString)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "Version \(short)"
    }

    private func confirmUninstallHelper() {
        let alert = NSAlert()
        alert.messageText = "Uninstall the privileged helper?"
        alert.informativeText = """
        Fans will be returned to automatic, then the helper is removed from \
        /Library/PrivilegedHelperTools (admin password required).

        SpeedyFan keeps running read-only; the next manual fan change will \
        offer to reinstall the helper.
        """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            controller.uninstallHelper()
        }
    }
}
