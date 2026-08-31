import SwiftUI
import AppKit
import UserNotifications

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

// Four tabs: app housekeeping, what the fans do, what the menu bar shows,
// and when to speak up — without scattering related options across tabs the
// user has to hunt through. Grouping *within* a tab is done with section
// headers instead of another tab.
enum SettingsTab: String, CaseIterable {
    case general, fans, menuBar, notifications

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
        case .notifications: return "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .fans: return "fan.fill"
        case .menuBar: return "menubar.rectangle"
        case .notifications: return "bell.badge"
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
        case .notifications: controller = NSHostingController(rootView: AnyView(NotificationSettingsTab().paneWidth()))
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
    @AppStorage(SettingsKey.boostReleaseMargin) private var boostReleaseMargin =
        AppSettings.boostReleaseMarginDefault
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.system.rawValue

    private var useF: Bool { Temperature.usesFahrenheit(setting: temperatureUnitRaw) }

    /// The temperature the boost lets go at, and its formatted form.
    private var releaseTemp: Int { maxFansAtTemp - boostReleaseMargin }

    private var releaseTempText: String {
        Temperature.format(Double(releaseTemp), fahrenheit: useF)
    }

    /// Top of the idle band this tab already quotes. A release temperature
    /// down here is one the machine only reaches when it has stopped working.
    private let idleCeiling = 80

    private var sensorCountText: String {
        let count = controller.sensorReadings.count
        return count > 0 ? " of the \(count) on this Mac" : ""
    }

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
                Note("""
                If the hottest sensor reaches this while fans are set by \
                hand, they all return to automatic. Judged on the live \
                reading rather than a smoothed one — a real spike should act \
                at once.
                """)
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
                Picker("Hold until it cools by", selection: Binding(
                    get: { boostReleaseMargin },
                    set: { boostReleaseMargin = $0; controller.enforceMaxBoost() }
                )) {
                    ForEach(Array(stride(from: AppSettings.boostReleaseMarginRange.lowerBound,
                                         through: AppSettings.boostReleaseMarginRange.upperBound,
                                         by: 5)), id: \.self) { delta in
                        Text(Temperature.formatDelta(delta, fahrenheit: useF))
                            .tag(delta)
                    }
                }
                .disabled(maxFansAtTemp == 0)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Note("""
                    All fans go to full speed when the hottest sensor reaches \
                    this — overriding automatic and manual — and stay there \
                    until it falls to \(releaseTempText). Judged on the \
                    median of the last ten seconds, not a single reading: the \
                    hottest-sensor figure swings several degrees between \
                    samples.
                    """)
                    // The wide margins are only safe against a high trigger.
                    // Naming a release temperature the machine reaches only
                    // at rest would hold the fans at full speed for ages.
                    if maxFansAtTemp > 0, releaseTemp <= idleCeiling {
                        Label("""
                        \(releaseTempText) is around this Mac's idle \
                        temperature, so the fans could stay at full speed for \
                        a long time. Pair a wide margin with a higher trigger.
                        """, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                // The number most likely to be set wrongly is a threshold
                // chosen against a PC-shaped intuition about idle temps.
                Note("""
                Every temperature SpeedyFan shows or acts on is the hottest \
                single sensor\(sensorCountText), never an average — one hot \
                core is what matters. Apple silicon sensors read \
                \(Temperature.formatRange(70, 80, fahrenheit: useF)) at idle; \
                the panel's Sensors list shows what this Mac reports.
                """)
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
                Speed readings report the busiest fan and the temperature the \
                hottest sensor — maximums, not averages. Turn everything off \
                to hide SpeedyFan from the menu bar — it keeps running, and \
                the icon comes back next launch so you can't lock yourself \
                out.
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
                            .fill(helperState.tint)
                            .frame(width: 7, height: 7)
                        Text(helperState.label)
                            .foregroundStyle(.secondary)
                    }
                }
                // Mirrors the state above rather than sitting there dimmed:
                // uninstalling is only reasonable if it can be undone from
                // the same place it was done.
                HStack {
                    switch helperState {
                    case .missing:
                        Button("Install Helper…") { controller.installHelper() }
                    case .stale:
                        // Installing over the top is the update, so this is
                        // the same action under the name that describes it.
                        Button("Update Helper…") { controller.installHelper() }
                        Button("Uninstall Helper…") { confirmUninstallHelper() }
                    case .current:
                        Button("Uninstall Helper…") { confirmUninstallHelper() }
                    }
                }
                .disabled(controller.busy)
                // Both buttons can fail — a cancelled password prompt is the
                // common one — and the panel that normally reports errors
                // isn't open while the settings window is.
                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Note(helperState.explanation)
            }

            Section {
                LabeledContent("SpeedyFan", value: versionString)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The helper's three real states. Kept as one value so the dot, the
    /// wording and the buttons can't disagree with each other.
    private enum HelperState {
        case missing, stale, current

        var label: String {
            switch self {
            case .missing: return "Not installed"
            case .stale: return "Update available"
            case .current: return "Installed"
            }
        }

        var tint: Color { self == .current ? .green : .orange }

        var explanation: String {
            switch self {
            case .missing:
                return """
                Fan changes need admin rights. Installing asks for an admin \
                password once, after which changes apply silently — or just \
                move a fan slider and SpeedyFan will ask then.
                """
            case .stale:
                return """
                SpeedyFan has been updated but the installed helper hasn't. \
                Fan control still works; updating applies the newer helper \
                and asks for an admin password once.
                """
            case .current:
                return """
                Fan changes need admin rights, so SpeedyFan installs a small \
                helper once. Uninstalling returns fans to automatic; \
                SpeedyFan keeps working read-only.
                """
            }
        }
    }

    private var helperState: HelperState {
        guard controller.helperInstalled else { return .missing }
        return controller.helperStale ? .stale : .current
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

        SpeedyFan keeps running read-only. This button becomes “Install \
        Helper…” afterwards, and any manual fan change will offer to \
        reinstall it too.
        """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            controller.uninstallHelper()
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    @AppStorage(SettingsKey.notifyFailsafe) private var notifyFailsafe = true
    @AppStorage(SettingsKey.notifyStuckFan) private var notifyStuckFan = true
    @AppStorage(SettingsKey.notifyBoost) private var notifyBoost = true
    @AppStorage(SettingsKey.notifyReturnToAuto) private var notifyReturnToAuto = true
    @AppStorage(SettingsKey.notificationSound) private var notificationSound = true

    /// nil until the first async query answers (or forever, running unbundled
    /// via `swift run`, where UNUserNotificationCenter isn't available).
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Form {
            Section {
                Toggle("Thermal failsafe", isOn: $notifyFailsafe)
                Toggle("Stuck fan", isOn: $notifyStuckFan)
            } header: {
                Text("Safety alerts")
            } footer: {
                Note("""
                When the failsafe returns hot fans to automatic, and when a \
                fan is commanded to spin but isn't turning. If banners are \
                unavailable these show as alert windows instead; switching \
                them off here silences them entirely. The protections \
                themselves always act, and a failed emergency return to \
                automatic always alerts.
                """)
            }

            Section {
                Toggle("Maximum fans", isOn: $notifyBoost)
                Toggle("Returned to automatic", isOn: $notifyReturnToAuto)
            } header: {
                Text("Automation")
            } footer: {
                Note("""
                Maximum fans covers engaging and releasing, once per bout of \
                heat however many times the fans are called on during it. \
                Returned to automatic covers the manual time limit, and \
                leftover manual control cleaned up at launch.
                """)
            }

            Section {
                Toggle("Play sound", isOn: $notificationSound)
            } footer: {
                Note("The standard notification sound, on banners only.")
            }

            Section {
                LabeledContent("macOS notifications") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Open System Settings…") { openNotificationSettings() }
            } footer: {
                Note("""
                macOS asks for permission the first time SpeedyFan posts a \
                banner. If it was denied, allow SpeedyFan under System \
                Settings → Notifications.
                """)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshAuthorization)
        // Coming back from System Settings should show the new answer.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAuthorization()
        }
    }

    private var statusText: String {
        switch authorization {
        case .authorized, .provisional: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested yet"
        default: return "Unknown"
        }
    }

    private var statusColor: Color {
        switch authorization {
        case .authorized, .provisional: return .green
        case .denied: return .orange
        default: return .gray
        }
    }

    private func refreshAuthorization() {
        // Same guard as Notifier: no bundle (bare `swift run`) means no
        // notification center to ask.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorization = settings.authorizationStatus
            }
        }
    }

    private func openNotificationSettings() {
        // The Ventura+ Notifications pane; if a future macOS renames the
        // anchor, fall back to System Settings itself.
        for raw in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                    "x-apple.systempreferences:"] {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
