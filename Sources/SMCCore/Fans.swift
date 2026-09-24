// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

// Fan-level API on top of the raw SMC client. Key scheme (same on Intel and
// Apple Silicon, values are `flt` on M-series):
//   FNum    number of fans
//   F<n>Ac  actual RPM          F<n>Tg  target RPM
//   F<n>Mn  minimum RPM         F<n>Mx  maximum RPM  (read-only on M-series)
//   F<n>Md  mode (0 auto, 1 forced/manual)
//   Ftst    thermal-test flag; some M-series firmwares only honor F<n>Md
//           after Ftst is set to 1 and thermalmonitord yields control.

public struct FanStatus: Codable, Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let actualRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double
    public let manual: Bool

    public init(id: Int, name: String, actualRPM: Double, minRPM: Double,
                maxRPM: Double, targetRPM: Double, manual: Bool) {
        self.id = id
        self.name = name
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.manual = manual
    }
}

public enum Fans {
    static func modeKey(_ id: Int) -> String? {
        for k in ["F\(id)Md", "F\(id)md"] where activeSMC.hasKey(k) { return k }
        return nil
    }

    public static func count() -> Int {
        (try? activeSMC.readNumber("FNum")).map(Int.init) ?? 0
    }

    public static func name(_ id: Int) -> String {
        // F<n>ID is a {fds struct whose bytes 4..15 hold a location string
        // ("Left", "Right", "Exhaust", ...). Not present on all machines.
        if let (info, b) = try? activeSMC.readBytes("F\(id)ID"),
           info.dataType == "{fds", b.count >= 16 {
            let strBytes = b[4..<16].prefix { $0 != 0 }
            if let s = String(bytes: strBytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces), !s.isEmpty {
                return s
            }
        }
        return "Fan \(id + 1)"
    }

    public static func status(_ id: Int) throws -> FanStatus {
        let smc = activeSMC
        let manual: Bool
        if let mk = modeKey(id), let m = try? smc.readNumber(mk) {
            // Not a boolean: F<n>Md is a flag word. Writing 1 forces a fan,
            // but this Mac's firmware reports *3* for a fan it has parked
            // itself (target 0, blades stopped) when the machine is cool —
            // which is the state it wakes up in. So non-zero means "not plain
            // automatic", nothing more; deciding whether a *person* asked for
            // the current speed needs the target too (FanController.isPinned).
            manual = m >= 0.5
        } else {
            manual = false
        }
        return FanStatus(
            id: id,
            name: name(id),
            actualRPM: try smc.readNumber("F\(id)Ac"),
            minRPM: (try? smc.readNumber("F\(id)Mn")) ?? 0,
            maxRPM: (try? smc.readNumber("F\(id)Mx")) ?? 6000,
            targetRPM: (try? smc.readNumber("F\(id)Tg")) ?? 0,
            manual: manual)
    }

    public static func all() -> [FanStatus] {
        (0..<count()).compactMap { try? status($0) }
    }

    // MARK: - Control (requires root)

    /// Put a fan into forced mode. On some Apple Silicon firmwares the first
    /// write silently doesn't stick until Ftst=1 is set, so verify and retry.
    static func setManualMode(_ id: Int, _ manual: Bool) throws {
        guard let mk = modeKey(id) else { throw SMCError.keyNotFound("F\(id)Md") }
        let want: Double = manual ? 1 : 0
        try activeSMC.writeNumber(mk, want)
        if (try? activeSMC.readNumber(mk)) == want { return }

        if activeSMC.hasKey("Ftst") {
            try? activeSMC.writeNumber("Ftst", 1)
        }
        for _ in 0..<40 {
            usleep(100_000)
            try? activeSMC.writeNumber(mk, want)
            if (try? activeSMC.readNumber(mk)) == want { return }
        }
        throw SMCError.writeNotApplied(mk)
    }

    /// Force a fan to a fixed RPM, clamped to the fan's [min, max] range.
    public static func setSpeed(_ id: Int, rpm: Double) throws {
        let st = try status(id)
        let clamped = max(st.minRPM, min(st.maxRPM, rpm))
        try setManualMode(id, true)
        try activeSMC.writeNumber("F\(id)Tg", clamped)
    }

    /// Return a fan to automatic (firmware-controlled) speed.
    public static func setAuto(_ id: Int) throws {
        try setManualMode(id, false)
    }

    /// Return every fan to automatic and clear the thermal-test flag.
    public static func setAllAuto() throws {
        var firstError: Error?
        for id in 0..<count() {
            do { try setAuto(id) } catch { firstError = firstError ?? error }
        }
        if activeSMC.hasKey("Ftst"), (try? activeSMC.readNumber("Ftst")) != 0 {
            try? activeSMC.writeNumber("Ftst", 0)
        }
        if let e = firstError { throw e }
    }
}

// MARK: - Temperature

public enum Sensors {
    /// Discover plausible temperature keys once (T*** keys of type flt with a
    /// sane value). Apple Silicon key names are undocumented, so instead of a
    /// fixed table we take the hottest reading as a summary.
    public static func temperatureKeys() -> [String] {
        guard let total = try? activeSMC.keyCount() else { return [] }
        var keys: [String] = []
        for i in 0..<total {
            guard let key = try? activeSMC.keyAtIndex(i), key.hasPrefix("T") else { continue }
            guard let info = try? activeSMC.keyInfo(key),
                  info.dataType == "flt " || info.dataType == "sp78" else { continue }
            if let v = try? activeSMC.readNumber(key), v > 10, v < 120 {
                keys.append(key)
            }
        }
        return keys
    }

    /// Read every key, dropping sensors that are missing or implausible
    /// right now (a sensor that was sane at discovery can go bad later).
    public static func readings(_ keys: [String]) -> [SensorReading] {
        keys.compactMap { key in
            guard let v = try? activeSMC.readNumber(key), v > 10, v < 120
            else { return nil }
            return SensorReading(key: key, value: v)
        }
    }

    public static func hottest(_ keys: [String]) -> Double? {
        readings(keys).map(\.value).max()
    }
}

public struct SensorReading: Identifiable, Equatable {
    public let key: String
    public let value: Double
    public var id: String { key }

    public init(key: String, value: Double) {
        self.key = key
        self.value = value
    }
}

/// Version of the fanctl command set. The app reinstalls an older installed
/// helper before sending commands it wouldn't understand. Bump when fanctl
/// gains or changes commands.
public enum FanctlProtocol {
    // Not bumped when the `min` subcommand was dropped: the app simply stopped
    // calling it, so an already-installed v3 helper is still correct — and
    // bumping would force a reinstall, i.e. an admin password prompt, for
    // nothing.
    public static let version = 3
}
