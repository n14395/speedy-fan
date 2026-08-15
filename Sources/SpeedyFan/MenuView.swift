import SwiftUI
import AppKit
import SMCCore

struct MenuView: View {
    @ObservedObject var controller = FanController.shared
    // Only what the panel itself renders; everything configurable lives in
    // the settings window.
    @AppStorage(SettingsKey.linkFans) private var linkFans = true
    @AppStorage(SettingsKey.maxFansAtTemp) private var maxFansAtTemp = 0
    @AppStorage(SettingsKey.sensorsExpanded) private var sensorsExpanded = false
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.system.rawValue

    private var useF: Bool { Temperature.usesFahrenheit(setting: temperatureUnitRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if controller.fans.isEmpty {
                Text("No fans found on this Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if linkFans && controller.fans.count > 1 {
                LinkedFanRow()
            } else {
                ForEach(controller.fans) { fan in
                    FanRow(fan: fan)
                    if fan.id != controller.fans.last?.id { Divider() }
                }
            }
            if controller.tempHistory.count >= 2 {
                temperatureChart
            }
            if !controller.sensorReadings.isEmpty {
                sensorSection
            }
            captions
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(GeometryReader { proxy in
            MenuWindowBridge(contentHeight: proxy.size.height)
        })
    }

    private var header: some View {
        HStack {
            Image(systemName: "fan.fill")
            Text("SpeedyFan").font(.headline)
            Spacer()
            if let t = controller.hottestTemp {
                Label(Temperature.format(t, fahrenheit: useF),
                      systemImage: "thermometer.medium")
                    .font(.subheadline)
                    .foregroundStyle(t > 90 ? .red : .secondary)
                    .help("Hottest SMC temperature sensor")
            }
            settingsButton
        }
    }

    @ViewBuilder
    private var captions: some View {
        if !controller.stuckFans.isEmpty {
            Caption(stuckFanWarning, systemImage: "exclamationmark.triangle.fill",
                    tint: .red)
        }
        if controller.boostPinned {
            Caption("Maximum fans — full speed until below \(Temperature.format(Double(maxFansAtTemp - FanController.boostReleaseMargin), fahrenheit: useF))",
                    systemImage: "flame")
        }
        if controller.userManual {
            Caption("Failsafe — Auto at \(Temperature.format(Double(AppSettings.failsafeTemp), fahrenheit: useF))",
                    systemImage: "shield.lefthalf.filled")
            if let remaining = controller.revertRemaining {
                Caption("Returning to Auto in \(max(1, Int((remaining / 60).rounded(.up)))) min",
                        systemImage: "clock")
            }
        }
        Caption("Thermal pressure: \(ThermalPressure.label(controller.thermalState))",
                systemImage: "gauge.medium",
                tint: ThermalPressure.tint(controller.thermalState))
    }

    private var stuckFanWarning: String {
        let names = controller.fans
            .filter { controller.stuckFans.contains($0.id) }
            .map(\.name)
            .joined(separator: ", ")
        return "\(names) not spinning despite a commanded speed — the fan may be stuck"
    }

    /// Ten minutes of the hottest sensor, drawn from whatever polling
    /// actually happened. Time we weren't looking renders as a break in the
    /// line, not an invented ramp.
    private var temperatureChart: some View {
        let history = controller.tempHistory
        let lo = history.map(\.value).min() ?? 0
        let hi = history.map(\.value).max() ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            TempSparkline(history: history)
                .frame(height: 32)
            HStack {
                Text("last 10 min")
                Spacer()
                Text("\(Temperature.format(lo, fahrenheit: useF)) – \(Temperature.format(hi, fahrenheit: useF))")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature history")
        .accessibilityValue("between \(Temperature.format(lo, fahrenheit: useF)) and \(Temperature.format(hi, fahrenheit: useF)) over the last 10 minutes")
    }

    /// Collapsible list of the individual temperature sensors behind the
    /// header's hottest-sensor summary.
    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                sensorsExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sensorsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Sensors")
                        .font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Sensors")
            .accessibilityValue(sensorsExpanded ? "expanded" : "collapsed")
            if sensorsExpanded {
                ForEach(controller.sensorReadings.prefix(10)) { reading in
                    HStack(spacing: 4) {
                        Text(SensorName.label(for: reading.key))
                        Spacer()
                        trendArrow(for: reading.key)
                        Text(Temperature.format(reading.value, fahrenheit: useF))
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if controller.sensorReadings.count > 10 {
                    Text("…and \(controller.sensorReadings.count - 10) cooler sensors")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Arrow beside a sensor once ~20 s of readings show a direction.
    /// Steady (or not yet known) draws nothing, but the slot keeps its width
    /// so the temperature column doesn't shuffle as trends come and go.
    @ViewBuilder
    private func trendArrow(for key: String) -> some View {
        Group {
            switch controller.sensorTrends[key] {
            case .rising:
                Image(systemName: "arrow.up")
                    .accessibilityLabel("rising")
            case .falling:
                Image(systemName: "arrow.down")
                    .accessibilityLabel("falling")
            default:
                Color.clear
            }
        }
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(.tertiary)
        .frame(width: 9)
    }

    private var settingsButton: some View {
        Button {
            SettingsWindow.show()
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                // A bare glyph is a small target; pad the hit area out.
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("SpeedyFan settings")
        .accessibilityLabel("Settings")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.helperInstalled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(controller.helperInstalled
                     ? "Helper installed"
                     : "Helper not installed — first change will ask for an admin password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Full Blast") { controller.fullBlast() }
                    .disabled(controller.busy || controller.fans.isEmpty)
                Button("All Auto") { controller.setAllAuto() }
                    .disabled(controller.busy || !controller.userManual)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

}

// A status line explaining why the fans are doing what they're doing.
//
// Not a Label: inside the panel's fixed 320pt width Label truncates its text
// with an ellipsis instead of wrapping. Laying the glyph and text out
// directly — and letting the text keep its natural height — wraps instead.
private struct Caption: View {
    let text: String
    let systemImage: String
    let tint: Color?

    init(_ text: String, systemImage: String, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // Fixed width keeps the wrapped text aligned across captions,
            // whose glyphs are different widths.
            Image(systemName: systemImage)
                .frame(width: 12)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(tint ?? Color.secondary)
    }
}

// The sparkline itself: temperature over a fixed 10-minute window ending at
// the newest sample, "now" at the right edge. Runs of continuous observation
// are stroked as lines; gaps stay empty, and a sample with no neighbours
// close enough to connect to is drawn as a dot so it isn't invisible.
private struct TempSparkline: View {
    let history: [FanController.TempSample]

    var body: some View {
        Canvas { context, size in
            guard history.count >= 2, let last = history.last,
                  let lo = history.map(\.value).min(),
                  let hi = history.map(\.value).max() else { return }
            let window = FanController.historyWindow
            let start = last.time.addingTimeInterval(-window)
            // Pad the value domain so a near-flat line sits mid-frame
            // instead of magnifying sensor noise into drama.
            let span = max(hi - lo, 4)
            let mid = (hi + lo) / 2
            let bottom = mid - span / 2
            // Inset so the stroke and dots aren't clipped at the edges.
            let inset: CGFloat = 2
            func point(_ sample: FanController.TempSample) -> CGPoint {
                let x = sample.time.timeIntervalSince(start) / window
                let y = (sample.value - bottom) / span
                return CGPoint(
                    x: inset + x * (size.width - 2 * inset),
                    y: inset + (1 - y) * (size.height - 2 * inset))
            }
            for segment in FanController.gapSegments(
                history, gap: FanController.historyGap) {
                if segment.count == 1, let sample = segment.first {
                    let p = point(sample)
                    context.fill(
                        Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5,
                                               width: 3, height: 3)),
                        with: .style(.secondary))
                    continue
                }
                var path = Path()
                path.move(to: point(segment[0]))
                for sample in segment.dropFirst() {
                    path.addLine(to: point(sample))
                }
                context.stroke(
                    path, with: .style(.secondary),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                       lineJoin: .round))
            }
        }
    }
}

// Display mapping for the OS's own heat verdict (ProcessInfo.thermalState):
// unlike a raw sensor reading, this is macOS's judgment of whether the
// machine is comfortable, with Apple's per-model knowledge baked in.
enum ThermalPressure {
    nonisolated static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// nil means the caption's usual quiet secondary. Nominal and fair are
    /// everyday states (fair just means "working hard"); serious is where
    /// macOS starts throttling, and that deserves color.
    nonisolated static func tint(_ state: ProcessInfo.ThermalState) -> Color? {
        switch state {
        case .serious: return .orange
        case .critical: return .red
        default: return nil
        }
    }
}

// Two jobs the MenuBarExtra `.window` panel can't do from pure SwiftUI:
//
// 1. Height: the panel grows to fit new content but never shrinks back, so
//    hiding rows (e.g. toggling Link Fans or returning to Auto) leaves blank
//    space. Resize the hosting window to the content's natural height,
//    keeping the top edge anchored under the menu bar.
// 2. Visibility: FanController only polls the open menu, so it needs to know
//    when the panel shows and hides. onAppear/onDisappear are unreliable for
//    a window that is ordered in and out, so watch occlusion state instead.
private struct MenuWindowBridge: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {
        let contentHeight = contentHeight
        DispatchQueue.main.async {
            guard let window = view.window, contentHeight > 0 else { return }
            let current = window.contentRect(forFrameRect: window.frame).height
            let delta = contentHeight - current
            guard abs(delta) > 0.5 else { return }
            var frame = window.frame
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true)
        }
    }

    final class BridgeView: NSView {
        private var occlusionObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer = occlusionObserver {
                NotificationCenter.default.removeObserver(observer)
                occlusionObserver = nil
            }
            if let window {
                occlusionObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main
                ) { [weak window] _ in
                    let visible = window?.occlusionState.contains(.visible) ?? false
                    Task { @MainActor in FanController.shared.menuVisible = visible }
                }
            }
            FanController.shared.menuVisible =
                window?.occlusionState.contains(.visible) ?? false
        }

        deinit {
            if let observer = occlusionObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// One card controlling every fan together: single Auto/Manual switch and a
// 0–100% slider mapped onto each fan's own [min, max] range.
private struct LinkedFanRow: View {
    @ObservedObject var controller = FanController.shared
    @State private var dragging = false
    @State private var sliderValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fans").fontWeight(.medium)
                Spacer()
                Text(controller.fans.map { "\(Int($0.actualRPM))" }.joined(separator: " · ") + " RPM")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: Binding(
                get: { controller.userManual ? FanMode.manual : FanMode.auto },
                set: { controller.setModeAll($0) }
            )) {
                Text("Auto").tag(FanMode.auto)
                Text("Manual").tag(FanMode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.busy)
            .accessibilityLabel("Fan mode")

            if controller.userManual {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { dragging ? sliderValue : controller.linkedFraction },
                            set: {
                                sliderValue = $0
                                // Track the drag on the hardware, throttled.
                                if dragging {
                                    controller.applyManualLinkedLive(fraction: $0)
                                }
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if editing {
                                sliderValue = controller.linkedFraction
                                dragging = true
                            } else {
                                dragging = false
                                controller.applyManualLinked(fraction: sliderValue)
                            }
                        }
                    )
                    .accessibilityLabel("Fan speed")
                    .accessibilityValue("\(Int((dragging ? sliderValue : controller.linkedFraction) * 100)) percent")
                    Text("\(Int((dragging ? sliderValue : controller.linkedFraction) * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Text("Targets " + controller.fans.map { "\(Int($0.targetRPM))" }.joined(separator: " · ") + " RPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct FanRow: View {
    let fan: FanStatus
    @ObservedObject var controller = FanController.shared
    @State private var dragging = false
    @State private var sliderValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(fan.name).fontWeight(.medium)
                Spacer()
                Text("\(Int(fan.actualRPM)) RPM")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: Binding(
                get: { controller.userMode(of: fan) },
                set: { controller.setMode($0, fan: fan) }
            )) {
                Text("Auto").tag(FanMode.auto)
                Text("Manual").tag(FanMode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.busy)
            .accessibilityLabel("\(fan.name) mode")

            if controller.userMode(of: fan) == .manual {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { dragging ? sliderValue : (controller.manualTargets[fan.id] ?? fan.targetRPM) },
                            set: {
                                sliderValue = $0
                                // Track the drag on the hardware, throttled.
                                if dragging {
                                    controller.applyManualLive(fan: fan, rpm: $0)
                                }
                            }
                        ),
                        in: fan.minRPM...max(fan.minRPM + 1, fan.maxRPM),
                        onEditingChanged: { editing in
                            if editing {
                                sliderValue = controller.manualTargets[fan.id] ?? fan.targetRPM
                                dragging = true
                            } else {
                                dragging = false
                                controller.applyManual(fan: fan, rpm: sliderValue)
                            }
                        }
                    )
                    .accessibilityLabel("\(fan.name) speed")
                    .accessibilityValue("\(Int(dragging ? sliderValue : (controller.manualTargets[fan.id] ?? fan.targetRPM))) RPM")
                    Text("\(Int(dragging ? sliderValue : (controller.manualTargets[fan.id] ?? fan.targetRPM)))")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Text("Range \(Int(fan.minRPM))–\(Int(fan.maxRPM)) RPM · target \(Int(fan.targetRPM))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
