import CryptoKit
import Foundation
import SMCCore

// Manages the privileged fanctl helper. The app itself only ever reads the
// SMC; all writes go through the helper, which is installed once (one admin
// password prompt) as a setuid-root binary — the same pattern fan utilities
// like smcFanControl and Macs Fan Control use for silent subsequent writes.

enum HelperError: LocalizedError {
    case bundledHelperMissing
    case installFailed(String)
    case uninstallFailed(String)
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing: return "Bundled fanctl helper not found"
        case .installFailed(let s): return "Helper install failed: \(s)"
        case .uninstallFailed(let s): return "Helper uninstall failed: \(s)"
        case .runFailed(let s): return s
        }
    }
}

enum Helper {
    static let installedPath = "/Library/PrivilegedHelperTools/com.speedyfan.fanctl"

    /// The fanctl binary shipped next to the app: in the bundle's Resources
    /// when running as SpeedyFan.app, or next to the executable under
    /// `swift run` / `.build`.
    static var bundledPath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("fanctl").path,
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("fanctl").path,
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool {
        var st = stat()
        guard stat(installedPath, &st) == 0 else { return false }
        return st.st_uid == 0 && (st.st_mode & S_ISUID) != 0
    }

    /// Copy the bundled helper into place as root:wheel mode 4755. Prompts
    /// for an administrator password via osascript.
    static func install() throws {
        guard let src = bundledPath else { throw HelperError.bundledHelperMissing }
        let dst = installedPath
        let script = """
        mkdir -p /Library/PrivilegedHelperTools && \
        cp -f '\(src)' '\(dst)' && \
        chown root:wheel '\(dst)' && \
        chmod 4755 '\(dst)'
        """
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let (status, _, err) = run(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        guard status == 0, isInstalled else {
            throw HelperError.installFailed(err.isEmpty ? "cancelled" : err)
        }
    }

    /// Remove the privileged helper (one admin prompt). Fans are returned to
    /// automatic first, while the helper is still around to do it silently.
    static func uninstall() throws {
        if isInstalled { _ = run(installedPath, ["auto-all"]) }
        let script = "rm -f '\(installedPath)'"
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let (status, _, err) = run(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        guard status == 0, !isInstalled else {
            throw HelperError.uninstallFailed(err.isEmpty ? "cancelled" : err)
        }
    }

    /// Whether the installed helper differs from the one inside this app
    /// bundle. Compared by content, because `FanctlProtocol.version` only
    /// covers changes to the *command set*: a fix to how an existing command
    /// behaves ships in the app and would otherwise never reach the copy in
    /// /Library, where the privileged work actually happens.
    ///
    /// Unreadable or missing files are never reported stale — "we can't tell"
    /// must not become "update available", which would offer a password
    /// prompt that fixes nothing.
    static var installedIsStale: Bool {
        guard isInstalled, let bundled = bundledPath else { return false }
        guard let stamp = fileStamp(installedPath) else { return false }
        if let cached = staleCache, cached.stamp == stamp { return cached.stale }
        let stale = isStale(bundled: digest(bundled),
                            installed: digest(installedPath))
        staleCache = (stamp, stale)
        return stale
    }

    /// The comparison itself. A digest we couldn't compute reads as "not
    /// stale": offering an update we can't justify would cost a password
    /// prompt and fix nothing.
    static func isStale(bundled: String?, installed: String?) -> Bool {
        guard let bundled, let installed else { return false }
        return bundled != installed
    }

    /// Digesting two 140 KB files on every poll would be pure waste, so the
    /// verdict is cached against the installed file's identity. Any install
    /// or uninstall changes that identity, which invalidates it for free.
    private static var staleCache: (stamp: String, stale: Bool)?

    private static func fileStamp(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_ino)-\(st.st_size)-\(st.st_mtimespec.tv_sec)"
    }

    private static func digest(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    /// Command-set version of the installed helper. A helper predating the
    /// `version` subcommand reports 1; missing helper reports 0.
    static var installedVersion: Int {
        guard isInstalled else { return 0 }
        let (status, out, _) = run(installedPath, ["version"])
        guard status == 0 else { return 1 }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    /// Run the installed helper, installing it first if needed. An installed
    /// helper older than the app's command set is reinstalled the same way.
    static func fanctl(_ args: [String]) throws {
        if installedVersion < FanctlProtocol.version { try install() }
        let (status, _, err) = run(installedPath, args)
        guard status == 0 else {
            throw HelperError.runFailed(err.isEmpty ? "fanctl exited \(status)" : err)
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return (-1, "", error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
