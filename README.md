# SpeedyFan

A small macOS menu bar applet for Apple Silicon Macs that shows each fan's
current RPM and lets you switch any fan between **Auto** (firmware-controlled)
and **Manual** (fixed RPM via a slider, clamped to the fan's own min/max range).
Also shows the hottest SMC temperature sensor.

## How it works

It speaks the classic `AppleSMC` IOKit protocol (the same mechanism used by
smcFanControl, Macs Fan Control and exelban/stats):

- `FNum` — fan count; per fan: `F<n>Ac` actual, `F<n>Tg` target, `F<n>Mn`/`F<n>Mx`
  range, `F<n>Md` mode. Values are `flt` on M-series.
- `F<n>Md` is a flag word, not a boolean. Writing 1 forces a fan; but this
  machine's firmware reports **3** with `F<n>Tg = 0` for a fan it has *parked*
  itself — blades stopped, which is the normal cool/idle state and the state a
  Mac wakes up in. So "mode is non-zero" does not mean a person asked for the
  current speed. SpeedyFan only calls a fan manual when it is forced *and* its
  target is at least the fan's own minimum, which a park (target 0) never is
  and `setSpeed` (which clamps to `[min, max]`) always is.
- Reading needs no privileges. **Writing needs root**, so the app ships a tiny
  helper CLI (`fanctl`) and installs it once to
  `/Library/PrivilegedHelperTools/com.speedyfan.fanctl` as setuid-root
  (one admin password prompt, on your first manual change). After that,
  slider changes apply silently.
- On some M-series firmwares the mode write only sticks after setting the
  `Ftst` (thermal test) flag; the helper handles that unlock-and-retry dance.
- Safety: manual speeds are clamped to the fan's `[min, max]`; on quit the app
  returns any manually-pinned fan to auto; and a thermal failsafe forces all fans back to auto (with an alert) if any
  SMC sensor reaches the failsafe temperature (85–100 °C, default 95) while a
  fan is under manual control. Note the failsafe only runs while the app is
  running — if the app is force-killed with fans pinned, relaunch it (it
  restores auto at launch), run `sudo fanctl auto-all`, or reboot (SMC state
  resets on reboot).
- Sleep: the SMC keeps whatever it was last told and none of the app's timers
  run, so a pinned fan would otherwise keep spinning at that speed with the lid
  shut, unsupervised. SpeedyFan hands the fans back to the firmware on
  `NSWorkspace.willSleepNotification`, remembers what was pinned, and on
  `didWakeNotification` waits ~2 s for the SMC to settle before restoring those
  speeds. If nothing was pinned before sleep it asserts automatic instead, so
  the fans always come back in the state you left them.

## Options & features

The panel footer has one-click presets: **Full Blast** (all fans to their
maximum) and **All Auto**. The gear button in the panel header opens the
settings window, which groups everything configurable into three tabs —
General, Fans and Menu Bar — each option with a short explanation. It reopens
on the tab you used last, and resizes to fit whichever tab is showing.

- **Launch at Login** — registers via `SMAppService.mainApp`.
- **Helper tool** — install status, and an **Uninstall Helper** button that
  returns fans to automatic then removes the privileged helper (admin
  password). The next manual change reinstalls it.
- **Link Fans** (default on) — one Auto/Manual switch and a single 0–100 %
  slider drive all fans, each mapped onto its own min–max range. Turn off
  for independent per-fan sliders. Slider changes apply live while dragging
  (throttled to one write per 300 ms, on a serial queue so writes can't land
  out of order); the release position always lands last.
- **Return to Automatic After** — Never (default) / 15 / 30 / 60 minutes: a
  timer that returns manually-pinned fans to automatic, with a notification.
  The panel shows a countdown caption while active.
- **Failsafe Temperature** — 85 / 90 / 95 (default) / 100 °C: the
  hottest-sensor temperature at which the thermal failsafe kicks in.
- **Show temperatures in** — System setting (default, follows the macOS
  region's temperature unit) / Celsius / Fahrenheit. Display only: thresholds
  are stored in °C and the pickers simply show their °F equivalents.
- **Maximum Fans At** — Off (default) / 85–100 °C: when the hottest sensor
  reaches this temperature, every fan is driven to maximum — overriding Auto
  and manual pins — and held there until the sensor cools 10 °C below.
  Presented as Auto with a caption while holding (it's a heat response, not
  manual mode); the thermal failsafe skips fans boosted to maximum since they
  can't be under-cooling. Arming it keeps the app polling every 2 s.
- **Menu bar shows** — four independent switches: the fan icon, fan speed in
  RPM, fan speed as a percentage of maximum, and the hottest sensor
  temperature. Any combination works; readings are drawn in that order
  separated by "·", and RPM/% report the busiest fan. The fan icon doubles
  as a state light: outline while the firmware drives the fans, filled while
  a manual pin is active, and a flame while "Maximum Fans At" holds full
  speed — so a pinned fan is visible at a glance even with no readings
  selected.
- **Hide menu bar icon** — the same setting seen from the other side, in the
  same group: it switches on when nothing is selected and off when anything
  is, because a menu bar item with nothing to show is simply removed. Hiding
  is session-only — the icon returns on the next launch, and reopening the app
  (`open SpeedyFan.app` or double-click in Finder) brings it back immediately,
  so you can't lock yourself out of the UI. (Reopening deliberately does *not*
  override the setting while the settings window is open: you can see the
  switch and turn it back on yourself.)
- **Update Reading Every** — 1–20 seconds (default 2): how often the menu bar
  reading is republished. This is the menu bar's *own* timer, deliberately
  separate from the hardware poll, so a faster consumer (the open panel at
  1 s, or the 2 s safety supervision) can't drag the menu bar along with it.
  Disabled unless a reading is selected. The open panel always refreshes every
  second; with only the icon (or nothing) in the menu bar and the panel closed,
  the app doesn't poll at all — unless a fan is manual or "Maximum Fans At" is
  armed, when the failsafe keeps watching.

The panel also shows a **sparkline** of the hottest sensor over the last ten
minutes — drawn only from polls that actually happened, so time the app spent
not polling renders as a gap, not an invented ramp — and a collapsible
**Sensors** list showing the individual temperature sensors behind the
hottest-sensor summary. Sensor names are best-effort community knowledge
(borrowed from the MIT-licensed [exelban/stats](https://github.com/exelban/stats)
tables and keyed by chip generation, since e.g. `Tp09` is an efficiency core
on M1 but a performance core on M2); anything unnamed shows its raw four-char
SMC key — honest, and still enough to spot the hot one. Each sensor grows a
small rising/falling arrow once ~20 s of readings show a direction; movement
under 1 °C is treated as noise.

A permanent **thermal pressure** caption reports macOS's own heat verdict
(`ProcessInfo.thermalState`: Nominal / Fair / Serious / Critical, colored
from Serious up — the levels where macOS itself starts throttling). Unlike a
raw sensor reading it bakes in Apple's per-model knowledge of what's normal,
and it costs nothing: the OS pushes changes, so the app never polls for it.

**Stuck-fan alert**: a fan commanded to a real speed (target at or above its
own minimum) that reports essentially no rotation for 30 s of continuous
observation triggers an important notification and a red warning caption in
the panel — the one hardware fault a fan app can catch early. Observation
gaps (sleep, nothing polling) reset the clock rather than counting time
nobody measured, and a healthy spin-up never qualifies.

Notifications: "Maximum Fans At" posts a banner when it engages and releases,
and the thermal failsafe when it trips. If notifications are denied, only the
failsafe and the stuck-fan alert fall back to a modal alert — informational
messages just drop.

The thermal failsafe reports via a Notification Center banner (permission
asked on first use, modal alert as fallback); only a *failed* emergency
restore still shows a modal alert.

## Build & run

```sh
./build.sh        # builds SpeedyFan.app and packs SpeedyFan-<version>.dmg
open SpeedyFan.app
```

Every build also produces a versioned `.dmg` (the app plus a drag-to-install
Applications symlink) ready to attach to a GitHub release. The version comes
from `CFBundleShortVersionString` in `Info.plist` — bump it there before
cutting a release.

**Installing a downloaded build:** the app is ad-hoc signed, not notarized,
so macOS quarantines it after download. After dragging it to Applications,
either approve it under System Settings → Privacy & Security when first
blocked, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/SpeedyFan.app
```

(Proper Developer ID signing + notarization would remove that step, but needs
a paid Apple Developer account.)

Requires full Xcode (the bare Command Line Tools are missing the SwiftUI macro
plugins); `build.sh` auto-detects `/Applications/Xcode.app` or `Xcode-beta.app`.

The app icon is generated code-first: `tools/make-icon.swift` renders the
squircle + fan glyph at all sizes and `iconutil` packs `AppIcon.icns`
(`build.sh` regenerates it automatically if the .icns is missing).

## CLI

The helper doubles as a debug CLI:

```sh
.build/out/Products/Release/fanctl list   # JSON fan status (no root needed)
sudo fanctl set 0 4000                    # pin fan 0 to 4000 RPM
sudo fanctl auto 0                        # back to automatic
sudo fanctl auto-all                      # everything back to automatic
fanctl key F0Md                           # print one raw SMC key (no root)
```

## Uninstall

```sh
sudo rm /Library/PrivilegedHelperTools/com.speedyfan.fanctl
rm -rf SpeedyFan.app
```
