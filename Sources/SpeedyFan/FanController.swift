import Foundation
import SwiftUI
import AppKit
import SMCCore

// Per-fan control mode as shown in the UI.
enum FanMode: Int {
    case auto = 0
    case manual = 1
}

@MainActor
final class FanController: ObservableObject {
    static let shared = FanController()

    @Published var fans: [FanStatus] = []
    @Published var hottestTemp: Double?
    /// All plausible sensors from the latest refresh, hottest first.
    @Published var sensorReadings: [SensorReading] = []
    @Published var lastError: String?
    @Published var busy = false
    @Published var helperInstalled = Helper.isInstalled

    // Desired manual target per fan, kept locally so the slider doesn't
    // fight the periodic refresh while the user drags it.
    @Published var manualTargets: [Int: Double] = [:]

    /// Slider position for the linked row: the busiest fan's target as a
    /// fraction of its own range.
    ///
    /// Derived from the targets rather than remembered. A stored value starts
    /// at 0 and is only written by a gesture, so any manual state the app
    /// didn't create itself — fans found pinned at launch, or after a wake —
    /// used to render as 0% no matter how fast the fans were actually going.
    var linkedFraction: Double {
        fans.compactMap { fan -> Double? in
            guard fan.maxRPM > fan.minRPM else { return nil }
            let target = manualTargets[fan.id] ?? fan.targetRPM
            return (target - fan.minRPM) / (fan.maxRPM - fan.minRPM)
        }
        .max()
        .map { min(1, max(0, $0)) } ?? 0
    }

    // Seconds until the auto-revert timer returns fans to automatic.
    @Published var revertRemaining: TimeInterval?

    /// True while "Maximum Fans At" is holding every fan at full speed.
    @Published private(set) var boostPinned = false

    /// Text for the menu bar item, republished only at the user's chosen
    /// interval. The menu bar reads this and nothing else, so hardware polls
    /// that run faster (open panel, supervision) can't drag it along.
    @Published private(set) var menuBarStat: String?

    private var tempKeys: [String] = []
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var statTimer: Timer?
    private var statItems: Set<MenuBarItem>?
    private var statInterval: TimeInterval?
    private var statUnitRaw: String?
    private var watchdogTripping = false
    private var watchdogAlerted = false
    private var revertDeadline: Date?

    /// Whether the popup menu is open (reported by MenuView's window bridge).
    /// Opening refreshes immediately so stale data never flashes on screen.
    var menuVisible = false {
        didSet {
            guard menuVisible != oldValue else { return }
            if menuVisible { refresh() }
            syncTimer()
        }
    }

    private init() {
        refresh()
        // Quit restores Auto (applicationWillTerminate), so manual fans at
        // launch mean a crashed/killed session or an external `fanctl set`.
        // Either way, never start pinned: launch always begins in Auto.
        // Uses the already-installed helper, so no password prompt.
        if anyManual && Helper.isInstalled {
            runHelper([["auto-all"]]) { error in
                if error == nil {
                    Notifier.post(
                        title: "SpeedyFan",
                        body: "Fans were still under manual control — returned to automatic.")
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let keys = Sensors.temperatureKeys()
            DispatchQueue.main.async { self?.tempKeys = keys; self?.refreshTemp() }
        }
        // Settings that feed the two timers (menu bar display mode and its
        // interval) can change from anywhere; resync on every defaults write.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                FanController.shared.syncTimer()
                FanController.shared.syncStatTimer()
            }
        }
        syncStatTimer()
    }

    // MARK: - Polling

    /// While any fan is manual the failsafe keeps watching temperatures even
    /// with nothing on screen; this cadence is deliberately not user-tunable.
    nonisolated static let failsafePollInterval: TimeInterval = 2

    /// How often the SMC is read on behalf of the *panel and the safety
    /// features*: every second while the panel is open, and every couple of
    /// seconds while manual mode or an armed "Maximum Fans At" needs
    /// watching. nil = neither applies.
    ///
    /// Deliberately says nothing about the menu bar. The menu bar has its own
    /// timer (`syncStatTimer`) so its cadence is exactly the user's setting —
    /// folding it in here would make the menu bar inherit whichever consumer
    /// happened to be fastest.
    nonisolated static func pollInterval(
        menuVisible: Bool, anyManual: Bool, boostArmed: Bool
    ) -> TimeInterval? {
        var intervals: [TimeInterval] = []
        if menuVisible { intervals.append(1) }
        if anyManual || boostArmed { intervals.append(failsafePollInterval) }
        return intervals.min()
    }

    private func syncTimer() {
        let desired = Self.pollInterval(
            menuVisible: menuVisible,
            anyManual: anyManual,
            boostArmed: AppSettings.maxFansAtTemp > 0)
        guard desired != timerInterval else { return }
        timerInterval = desired
        timer?.invalidate()
        timer = nil
        if let desired {
            timer = Timer.scheduledTimer(withTimeInterval: desired, repeats: true) { _ in
                Task { @MainActor in
                    FanController.shared.refresh()
                }
            }
        }
    }

    // MARK: - Menu bar cadence

    /// The menu bar item's own timer: it reads the SMC and republishes the
    /// stat at exactly the user's interval, independent of everything else.
    /// Nothing runs unless a *reading* is selected — the bare fan glyph (or a
    /// hidden menu bar item) has nothing to keep current.
    private func syncStatTimer() {
        let items = AppSettings.menuBarItems
        let interval = TimeInterval(AppSettings.refreshSeconds)
        let unitRaw = AppSettings.temperatureUnitRaw
        guard items != statItems || interval != statInterval
                || unitRaw != statUnitRaw else { return }
        statItems = items
        statInterval = interval
        statUnitRaw = unitRaw
        statTimer?.invalidate()
        statTimer = nil
        guard items.contains(where: \.isReading) else {
            menuBarStat = nil
            return
        }
        statTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in FanController.shared.statTick() }
        }
        // Changing the setting shouldn't leave a stale (or blank) menu bar
        // for a whole interval.
        statTick()
    }

    private func statTick() {
        refresh()
        let text = MenuBarLabel.statusText(items: AppSettings.menuBarItems,
                                           fans: fans, hottestTemp: hottestTemp,
                                           fahrenheit: Temperature.usesFahrenheit)
        if text != menuBarStat { menuBarStat = text }
    }

    func refresh() {
        fans = Fans.all()
        for fan in fans where manualTargets[fan.id] == nil {
            manualTargets[fan.id] = Self.isPinned(fan)
                ? fan.targetRPM : max(fan.minRPM, fan.actualRPM)
        }
        helperInstalled = Helper.isInstalled
        refreshTemp()
        checkAutoRevert()
        checkWatchdog()
        enforceMaxBoost()
        // Manual state may have just changed, and with it the polling needs.
        syncTimer()
    }

    private func refreshTemp() {
        guard !tempKeys.isEmpty else { return }
        let readings = Sensors.readings(tempKeys).sorted { $0.value > $1.value }
        sensorReadings = readings
        hottestTemp = readings.first?.value

        let now = Date()
        updateTrends(readings, at: now)
        if let hottest = hottestTemp {
            tempHistory = Self.appending(TempSample(time: now, value: hottest),
                                         to: tempHistory, window: Self.historyWindow)
        }
    }

    // MARK: - Sensor trends

    /// Direction a sensor has moved since its anchor reading ~20 s ago.
    /// Consecutive polls are too close together to mean anything (die sensors
    /// jitter a degree between seconds), so each sensor is compared against
    /// an older anchor instead of its previous sample.
    enum Trend { case rising, falling, steady }

    nonisolated static let trendInterval: TimeInterval = 20
    /// Ignore movement smaller than this — sensor noise, not a trend.
    nonisolated static let trendThreshold: Double = 1

    nonisolated static func trend(from old: Double, to new: Double,
                                  threshold: Double = trendThreshold) -> Trend {
        if new - old >= threshold { return .rising }
        if old - new >= threshold { return .falling }
        return .steady
    }

    @Published private(set) var sensorTrends: [String: Trend] = [:]
    private var sensorAnchors: [String: (value: Double, at: Date)] = [:]

    private func updateTrends(_ readings: [SensorReading], at now: Date) {
        for reading in readings {
            guard let anchor = sensorAnchors[reading.key] else {
                sensorAnchors[reading.key] = (reading.value, now)
                continue
            }
            let age = now.timeIntervalSince(anchor.at)
            if age > Self.trendInterval * 6 {
                // Polling stopped for a while (panel closed, sleep): the
                // anchor describes another era. Restart rather than reporting
                // a "trend" against stale data.
                sensorAnchors[reading.key] = (reading.value, now)
                sensorTrends.removeValue(forKey: reading.key)
            } else if age >= Self.trendInterval {
                sensorTrends[reading.key] = Self.trend(from: anchor.value,
                                                       to: reading.value)
                sensorAnchors[reading.key] = (reading.value, now)
            }
        }
    }

    // MARK: - Temperature history

    /// Rolling window of hottest-sensor readings behind the panel's
    /// sparkline. Recorded opportunistically — whenever something is already
    /// polling — so the graph never costs a poll of its own; gaps in the
    /// record stay gaps in the drawing.
    struct TempSample: Equatable {
        let time: Date
        let value: Double
    }

    nonisolated static let historyWindow: TimeInterval = 600
    /// Samples further apart than this aren't connected by a line: the space
    /// between them is time we weren't looking, not a measured ramp. Above
    /// the slowest legitimate cadence (the 20 s max menu bar interval).
    nonisolated static let historyGap: TimeInterval = 30

    @Published private(set) var tempHistory: [TempSample] = []

    nonisolated static func appending(_ sample: TempSample,
                                      to history: [TempSample],
                                      window: TimeInterval) -> [TempSample] {
        var kept = history.filter {
            sample.time.timeIntervalSince($0.time) <= window
        }
        kept.append(sample)
        return kept
    }

    /// Split history into runs of continuously-observed samples.
    nonisolated static func gapSegments(_ history: [TempSample],
                                        gap: TimeInterval) -> [[TempSample]] {
        var segments: [[TempSample]] = []
        var current: [TempSample] = []
        for sample in history {
            if let last = current.last,
               sample.time.timeIntervalSince(last.time) > gap {
                segments.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    // MARK: - Linked-fan math (pure)

    /// 0...1 position of a fan's actual speed within its own [min, max]
    /// range; nil for a degenerate range.
    nonisolated static func currentFraction(of fan: FanStatus) -> Double? {
        fan.maxRPM > fan.minRPM
            ? (fan.actualRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM) : nil
    }

    /// Map a 0...1 slider fraction onto a fan's own [min, max] range.
    nonisolated static func linkedRPM(_ fraction: Double, for fan: FanStatus) -> Double {
        fan.minRPM + max(0, min(1, fraction)) * (fan.maxRPM - fan.minRPM)
    }

    // MARK: - Mode & speed

    /// Whether a fan is forced to a speed *someone asked for*.
    ///
    /// Forced mode alone isn't enough: this Mac's firmware also uses it to
    /// park a fan, reporting mode 1 with a target of 0 — below the fan's own
    /// minimum, which `setSpeed` can never produce because it clamps to
    /// [min, max]. Parked fans are the normal cool-and-idle state (and the
    /// state a machine wakes up in), so reading them as manual control is what
    /// made the panel claim "Manual, 0%" after sleep.
    nonisolated static func isPinned(_ fan: FanStatus) -> Bool {
        fan.manual && fan.targetRPM >= max(1, fan.minRPM)
    }

    func mode(of fan: FanStatus) -> FanMode {
        Self.isPinned(fan) ? .manual : .auto
    }

    var anyManual: Bool {
        fans.contains(where: Self.isPinned)
    }

    /// Manual mode as the UI presents it. A boost pin is still conceptually
    /// Auto (temperature-driven automation, not a user gesture), so pickers
    /// and sliders only treat user-initiated control as Manual.
    var userManual: Bool { anyManual && !boostPinned }

    func userMode(of fan: FanStatus) -> FanMode {
        boostPinned ? .auto : mode(of: fan)
    }

    func setMode(_ mode: FanMode, fan: FanStatus) {
        switch mode {
        case .auto:
            boostPinned = false
            runHelper([["auto", String(fan.id)]])
        case .manual:
            let target = manualTargets[fan.id] ?? max(fan.minRPM, fan.actualRPM)
            applyManual(fan: fan, rpm: target)
        }
    }

    func applyManual(fan: FanStatus, rpm: Double, live: Bool = false) {
        boostPinned = false
        manualTargets[fan.id] = rpm
        scheduleAutoRevert()
        runHelper([["set", String(fan.id), String(Int(rpm))]], live: live)
    }

    // MARK: - Live (mid-drag) apply

    /// Minimum spacing between hardware writes while a slider is dragged.
    nonisolated static let liveApplyInterval: TimeInterval = 0.3
    private var lastLiveApply = Date.distantPast

    /// Mid-drag apply: the fans track the slider as it moves instead of
    /// jumping on release. Throttled so a drag doesn't queue a helper process
    /// per pixel; the unthrottled drag-end apply always lands the final
    /// position.
    func applyManualLive(fan: FanStatus, rpm: Double) {
        guard Date().timeIntervalSince(lastLiveApply) >= Self.liveApplyInterval
        else { return }
        lastLiveApply = Date()
        applyManual(fan: fan, rpm: rpm, live: true)
    }

    func applyManualLinkedLive(fraction: Double) {
        guard Date().timeIntervalSince(lastLiveApply) >= Self.liveApplyInterval
        else { return }
        lastLiveApply = Date()
        applyManualLinked(fraction: fraction, live: true)
    }

    /// Linked control: all fans in one gesture. `fraction` is 0...1 mapped
    /// onto each fan's own [min, max] range.
    func setModeAll(_ mode: FanMode) {
        switch mode {
        case .auto:
            boostPinned = false
            runHelper([["auto-all"]])
        case .manual:
            // Start from the busiest fan's current position so switching to
            // manual doesn't audibly jump the speed.
            let fraction = fans.compactMap(Self.currentFraction).max() ?? 0
            applyManualLinked(fraction: fraction)
        }
    }

    func applyManualLinked(fraction: Double, live: Bool = false) {
        boostPinned = false
        let clamped = max(0, min(1, fraction))
        var commands: [[String]] = []
        for fan in fans {
            let rpm = Self.linkedRPM(clamped, for: fan)
            manualTargets[fan.id] = rpm
            commands.append(["set", String(fan.id), String(Int(rpm))])
        }
        guard !commands.isEmpty else { return }
        scheduleAutoRevert()
        runHelper(commands, live: live)
    }

    // MARK: - Presets

    func fullBlast() {
        guard !fans.isEmpty else { return }
        boostPinned = false
        var commands: [[String]] = []
        for fan in fans {
            manualTargets[fan.id] = fan.maxRPM
            commands.append(["set", String(fan.id), String(Int(fan.maxRPM))])
        }
        scheduleAutoRevert()
        runHelper(commands)
    }

    func setAllAuto() {
        boostPinned = false
        runHelper([["auto-all"]])
    }

    // MARK: - Maximum fans at temperature

    /// Once boosted, stay at full speed until the sensor cools this many °C
    /// below the trigger, so the boost doesn't flap around the threshold.
    nonisolated static let boostReleaseMargin = 10

    enum BoostAction: Equatable {
        case boost, release, hold
    }

    /// One supervision step for "Maximum Fans At". `armedTemp` is nil when
    /// the setting is off. Boost overrides user-manual control too — it's a
    /// heat response, and full speed can't under-cool. A missing reading
    /// while boosted releases rather than holding blind.
    nonisolated static func boostAction(
        pinned: Bool, armedTemp: Int?, hottest: Double?
    ) -> BoostAction {
        guard let armedTemp else { return pinned ? .release : .hold }
        if pinned {
            guard let hottest, hottest > Double(armedTemp - boostReleaseMargin)
            else { return .release }
            return .hold
        }
        guard let hottest, hottest >= Double(armedTemp) else { return .hold }
        return .boost
    }

    /// Called from every refresh, and directly when the setting changes.
    func enforceMaxBoost() {
        guard Helper.isInstalled, !busy, !fans.isEmpty else { return }
        // The failsafe, quit restore, or an external `fanctl auto-all` can
        // release the pin behind our back.
        if boostPinned && !anyManual { boostPinned = false }

        let armed = AppSettings.maxFansAtTemp
        switch Self.boostAction(pinned: boostPinned,
                                armedTemp: armed == 0 ? nil : armed,
                                hottest: hottestTemp) {
        case .boost:
            boostPinned = true
            var commands: [[String]] = []
            for fan in fans {
                manualTargets[fan.id] = fan.maxRPM
                commands.append(["set", String(fan.id), String(Int(fan.maxRPM))])
            }
            let useF = Temperature.usesFahrenheit
            let trigger = Temperature.format(Double(armed), fahrenheit: useF)
            let release = Temperature.format(
                Double(armed - Self.boostReleaseMargin), fahrenheit: useF)
            runHelper(commands) { error in
                if error == nil {
                    Notifier.post(
                        title: "SpeedyFan",
                        body: "A sensor reached \(trigger) — fans at maximum until it cools below \(release).")
                }
            }
        case .release:
            boostPinned = false
            runHelper([["auto-all"]]) { error in
                if error == nil {
                    Notifier.post(
                        title: "SpeedyFan",
                        body: "Maximum fans released — fans back to automatic.")
                }
            }
        case .hold:
            break
        }
    }

    // MARK: - Auto-revert timer

    private func scheduleAutoRevert() {
        let minutes = AppSettings.autoRevertMinutes
        revertDeadline = minutes > 0
            ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
    }

    private func checkAutoRevert() {
        if !anyManual || AppSettings.autoRevertMinutes == 0 {
            revertDeadline = nil
        }
        if let deadline = revertDeadline, Date() >= deadline, !busy {
            revertDeadline = nil
            runHelper([["auto-all"]]) { error in
                if error == nil {
                    Notifier.post(
                        title: "SpeedyFan",
                        body: "Manual time limit reached — fans returned to automatic.")
                }
            }
        }
        revertRemaining = revertDeadline.map { max(0, $0.timeIntervalSinceNow) }
    }

    // MARK: - Thermal failsafe

    private func checkWatchdog() {
        if !anyManual { watchdogAlerted = false }
        // A boost pin is exempt: fans at maximum can't be under-cooling, and
        // bouncing them to Auto would just fight the boost with alerts.
        guard !watchdogTripping, anyManual, !boostPinned,
              let temp = hottestTemp, temp >= Double(AppSettings.failsafeTemp)
        else { return }
        watchdogTripping = true
        runHelper([["auto-all"]]) { [weak self] error in
            guard let self else { return }
            if error == nil {
                Notifier.post(
                    title: "SpeedyFan thermal failsafe",
                    body: "A sensor reached \(Temperature.format(temp, fahrenheit: Temperature.usesFahrenheit)) while fans were under manual control. All fans have been returned to automatic.",
                    important: true)
                self.watchdogAlerted = false
            } else if !self.watchdogAlerted {
                // Failure is act-now territory: modal, but only once —
                // retries continue silently every tick.
                Notifier.alert(
                    "SpeedyFan thermal failsafe",
                    "A sensor reached \(Temperature.format(temp, fahrenheit: Temperature.usesFahrenheit)) while fans were under manual control, but returning them to automatic FAILED. Run `sudo fanctl auto-all` or reboot.")
                self.watchdogAlerted = true
            }
            self.watchdogTripping = false
        }
    }

    // MARK: - Sleep and wake

    /// What the user had asked for when the machine went to sleep, so waking
    /// can put it back. nil means they were in Auto.
    private var preSleepTargets: [Int: Double]?

    /// The SMC doesn't accept writes reliably the instant the machine wakes,
    /// so let it settle before re-asserting anything.
    static let wakeSettleDelay: TimeInterval = 2

    /// Sleep doesn't touch the SMC: a fan left in forced mode keeps spinning at
    /// that speed with the lid shut, and none of our supervision runs to stop
    /// it. Hand the fans back to the firmware on the way down and remember
    /// what to restore.
    func prepareForSleep() {
        NSLog("SpeedyFan: sleeping (fans %@)", describeFans())
        // A boost pin is a response to heat, not a user setting: it should not
        // come back on wake, and the supervision will re-arm it if needed.
        preSleepTargets = userManual
            ? fans.filter(Self.isPinned).reduce(into: [Int: Double]()) {
                $0[$1.id] = manualTargets[$1.id] ?? $1.targetRPM
            }
            : nil
        boostPinned = false
        guard Helper.isInstalled, anyManual else { return }
        // Synchronous: the sleep notification gives us very little time, and a
        // background hop would very likely not finish before the machine goes.
        try? Helper.fanctl(["auto-all"])
    }

    /// Put back what the user had, and — just as importantly — assert Auto if
    /// they had nothing pinned. Whatever the SMC reports at wake, the fans end
    /// up in the state the user last chose rather than in whatever survived.
    func resumeAfterWake() {
        NSLog("SpeedyFan: woke (fans %@), restoring %@",
              describeFans(Fans.all()),
              preSleepTargets.map { "\($0.count) pinned" } ?? "automatic")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettleDelay) { [weak self] in
            self?.applyWakeState()
        }
    }

    private func applyWakeState() {
        refresh()
        let targets = preSleepTargets
        preSleepTargets = nil
        guard Helper.isInstalled else { return }
        if let targets, !targets.isEmpty {
            for (id, rpm) in targets { manualTargets[id] = rpm }
            runHelper(targets.sorted { $0.key < $1.key }.map { id, rpm in
                ["set", String(id), String(Int(rpm))]
            }) { [weak self] _ in
                NSLog("SpeedyFan: restored pre-sleep fan speeds (%@)",
                      self?.describeFans() ?? "")
            }
        } else if anyManual {
            // Nothing was pinned before sleep, so anything forced now didn't
            // come from the user.
            runHelper([["auto-all"]]) { [weak self] _ in
                NSLog("SpeedyFan: nothing was pinned before sleep, forced automatic (%@)",
                      self?.describeFans() ?? "")
            }
        }
    }

    /// Compact fan summary for the sleep/wake log lines.
    private func describeFans(_ list: [FanStatus]? = nil) -> String {
        (list ?? fans)
            .map { "\($0.id):\(Self.isPinned($0) ? "pinned" : "auto")@\(Int($0.actualRPM))" }
            .joined(separator: " ")
    }

    // MARK: - Helper plumbing

    /// Called on app termination: never leave fans pinned after quit.
    nonisolated func restoreAutoIfNeeded() {
        guard Helper.isInstalled else { return }
        let anyManual = Fans.all().contains(where: Self.isPinned)
        if anyManual { try? Helper.fanctl(["auto-all"]) }
    }

    func uninstallHelper() {
        busy = true
        lastError = nil
        Self.helperQueue.async {
            var errorText: String?
            do { try Helper.uninstall() } catch { errorText = error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = false
                self.lastError = errorText
                self.refresh()
            }
        }
    }

    /// One serial queue for every helper invocation. Live slider writes
    /// stream in while earlier ones are still executing; on a concurrent
    /// queue two fanctl processes could land in either order and leave the
    /// fans at a stale speed.
    private static let helperQueue = DispatchQueue(
        label: "com.speedyfan.helper", qos: .userInitiated)

    /// Run one or more fanctl commands in order. The completion receives nil
    /// on success or the first command's error. `live` marks a throttled
    /// mid-drag write: it skips the busy flag (whose on/off pulsing would
    /// flicker-disable the panel's controls at the throttle cadence) and the
    /// follow-up refresh (the drag-end apply does a full one).
    private func runHelper(_ commands: [[String]], live: Bool = false,
                           completion: ((Error?) -> Void)? = nil) {
        if !live { busy = true }
        lastError = nil
        Self.helperQueue.async {
            var failure: Error?
            for args in commands {
                do { try Helper.fanctl(args) } catch {
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async {
                if let failure { self.lastError = failure.localizedDescription }
                if !live {
                    self.busy = false
                    self.refresh()
                }
                completion?(failure)
            }
        }
    }
}
