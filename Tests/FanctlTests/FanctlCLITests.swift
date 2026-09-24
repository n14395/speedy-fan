// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
import SMCCore

/// Integration tests that execute the built fanctl binary. Only read-only
/// and argument-validation paths are driven; every mutating subcommand is
/// refused before it reaches the SMC because the tests don't run as root.
final class FanctlCLITests: XCTestCase {

    private var fanctlURL: URL {
        productsDirectory.appendingPathComponent("fanctl")
    }

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn't locate the test bundle")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: fanctlURL.path),
            "fanctl binary not found next to the test bundle")
    }

    @discardableResult
    private func run(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = fanctlURL
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? "")
    }

    // MARK: - Usage / argument validation

    func testNoArgumentsFailsWithUsage() throws {
        let r = try run([])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("usage:"))
        XCTAssertTrue(r.out.isEmpty)
    }

    func testUnknownSubcommandFailsWithUsage() throws {
        let r = try run(["defrost"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("usage:"))
    }

    func testSetRejectsBadArguments() throws {
        // Wrong arity, non-numeric, negative, and absurd RPMs are all
        // rejected before any privilege or hardware access.
        for args in [["set"], ["set", "0"], ["set", "0", "fast"],
                     ["set", "0", "-100"], ["set", "0", "25000"],
                     ["set", "0", "3000", "extra"]] {
            let r = try run(args)
            XCTAssertEqual(r.status, 1, "expected failure for \(args)")
            XCTAssertTrue(r.err.contains("usage:"), "expected usage for \(args)")
        }
    }

    func testAutoRejectsWrongArity() throws {
        for args in [["auto"], ["auto", "0", "1"]] {
            let r = try run(args)
            XCTAssertEqual(r.status, 1)
            XCTAssertTrue(r.err.contains("usage:"))
        }
    }

    func testRetiredMinSubcommandIsGone() throws {
        // `min` backed the removed "Minimum fan speed" feature; it must now
        // fall through to the usage error like any unknown subcommand.
        let r = try run(["min", "0", "3000"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("usage:"))
        XCTAssertFalse(r.err.contains("min <fan>"), "usage still advertises min")
    }

    func testKeyRejectsWrongArity() throws {
        for args in [["key"], ["key", "FNum", "extra"]] {
            let r = try run(args)
            XCTAssertEqual(r.status, 1, "expected failure for \(args)")
            XCTAssertTrue(r.err.contains("usage:"), "expected usage for \(args)")
        }
    }

    func testKeyReadsARealKeyWithoutRoot() throws {
        // FNum exists on any Mac with fans; the value is a small count.
        let r = try run(["key", "FNum"])
        XCTAssertEqual(r.status, 0, r.err)
        let value = Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(value)
        XCTAssertGreaterThanOrEqual(value ?? -1, 0)
    }

    func testKeyFailsCleanlyOnMissingKey() throws {
        let r = try run(["key", "ZZZZ"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("not found"), r.err)
    }

    func testVersionPrintsCommandSetVersion() throws {
        let r = try run(["version"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines),
                       String(FanctlProtocol.version))
    }

    // MARK: - Privilege gating

    func testMutatingCommandsRequireRoot() throws {
        try XCTSkipIf(geteuid() == 0, "running as root; gating not observable")
        for args in [["set", "0", "3000"], ["auto", "0"], ["auto-all"]] {
            let r = try run(args)
            XCTAssertEqual(r.status, 1, "expected refusal for \(args)")
            XCTAssertTrue(r.err.contains("requires root"),
                          "expected root refusal for \(args), got: \(r.err)")
        }
    }

    // MARK: - list (read-only)

    func testListPrintsDecodableFanStatusJSON() throws {
        let r = try run(["list"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.err.isEmpty)

        let data = try XCTUnwrap(r.out.data(using: .utf8))
        let fans = try JSONDecoder().decode([FanStatus].self, from: data)

        // Hardware-independent invariants: ids are 0..<n in order, names
        // are non-empty, and each fan's range is sane.
        XCTAssertEqual(fans.map(\.id), Array(0..<fans.count))
        for fan in fans {
            XCTAssertFalse(fan.name.isEmpty)
            XCTAssertLessThanOrEqual(fan.minRPM, fan.maxRPM)
            XCTAssertGreaterThanOrEqual(fan.actualRPM, 0)
        }
    }

    func testListOutputIsPrettyPrintedWithSortedKeys() throws {
        let r = try run(["list"])
        let fans = try JSONDecoder().decode(
            [FanStatus].self, from: Data(r.out.utf8))
        try XCTSkipIf(fans.isEmpty, "no fans on this machine")
        // sortedKeys: "actualRPM" must appear before "manual" in each object.
        let first = try XCTUnwrap(r.out.range(of: "\"actualRPM\""))
        let manual = try XCTUnwrap(r.out.range(of: "\"manual\""))
        XCTAssertLessThan(first.lowerBound, manual.lowerBound)
    }
}
