// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SMCCore

/// Fan discovery, status, and control logic against the in-memory MockSMC.
final class FansTests: XCTestCase {
    var mock: MockSMC!

    override func setUp() {
        super.setUp()
        mock = MockSMC()
        activeSMC = mock
    }

    override func tearDown() {
        activeSMC = SMC.shared
        super.tearDown()
    }

    // MARK: - Discovery

    func testCountReadsFNum() {
        mock.setNumber("FNum", type: "flt ", 2)
        XCTAssertEqual(Fans.count(), 2)
    }

    func testCountIsZeroWithoutFNum() {
        XCTAssertEqual(Fans.count(), 0)
        XCTAssertEqual(Fans.all(), [])
    }

    // MARK: - Names

    func testNameParsesFdsLocationString() {
        mock.addFan(0, name: "Left")
        XCTAssertEqual(Fans.name(0), "Left")
    }

    func testNameTrimsWhitespace() {
        mock.addFan(0, name: " Exhaust ")
        XCTAssertEqual(Fans.name(0), "Exhaust")
    }

    func testNameFallsBackWithoutIDKey() {
        mock.addFan(0)
        XCTAssertEqual(Fans.name(0), "Fan 1")
        XCTAssertEqual(Fans.name(1), "Fan 2")
    }

    func testNameFallsBackOnWrongTypeOrEmptyString() {
        mock.addFan(0)
        mock.set("F0ID", type: "ch8*", bytes: Array(repeating: 65, count: 16))
        XCTAssertEqual(Fans.name(0), "Fan 1")

        mock.set("F0ID", type: "{fds", bytes: Array(repeating: 0, count: 16))
        XCTAssertEqual(Fans.name(0), "Fan 1")

        // Too short for the 16-byte {fds layout.
        mock.set("F0ID", type: "{fds", bytes: [0, 0, 0, 0, 65])
        XCTAssertEqual(Fans.name(0), "Fan 1")
    }

    // MARK: - Status

    func testStatusReadsAllKeys() throws {
        mock.setNumber("FNum", type: "flt ", 1)
        mock.addFan(0, actual: 1520, min: 1200, max: 5900, target: 1600,
                    mode: 1, name: "Right")
        let st = try Fans.status(0)
        XCTAssertEqual(st, FanStatus(
            id: 0, name: "Right", actualRPM: 1520, minRPM: 1200,
            maxRPM: 5900, targetRPM: 1600, manual: true))
    }

    func testStatusDefaultsForMissingOptionalKeys() throws {
        // Only actual RPM is required; the rest fall back.
        mock.setNumber("F0Ac", type: "flt ", 1800)
        let st = try Fans.status(0)
        XCTAssertEqual(st.minRPM, 0)
        XCTAssertEqual(st.maxRPM, 6000)
        XCTAssertEqual(st.targetRPM, 0)
        XCTAssertFalse(st.manual)
    }

    func testStatusThrowsWithoutActualRPM() {
        // Only optional keys present: the required F0Ac read must throw.
        mock.setNumber("F0Mn", type: "flt ", 1200)
        XCTAssertThrowsError(try Fans.status(0))
    }

    func testStatusHonorsLowercaseModeKey() throws {
        mock.setNumber("F0Ac", type: "flt ", 1500)
        mock.setNumber("F0md", type: "ui8 ", 1)
        XCTAssertTrue(try Fans.status(0).manual)
    }

    func testAllSkipsFansWhoseStatusThrows() {
        mock.setNumber("FNum", type: "flt ", 2)
        mock.addFan(0, actual: 1500)
        // Fan 1 exists per FNum but has no keys -> status throws -> skipped.
        let fans = Fans.all()
        XCTAssertEqual(fans.map(\.id), [0])
    }

    // MARK: - Control

    func testSetSpeedWritesModeThenClampedTarget() throws {
        mock.setNumber("FNum", type: "flt ", 1)
        mock.addFan(0, min: 1200, max: 6000)

        try Fans.setSpeed(0, rpm: 99999)
        XCTAssertEqual(mock.number("F0Md"), 1)
        XCTAssertEqual(mock.number("F0Tg"), 6000)

        try Fans.setSpeed(0, rpm: 100)
        XCTAssertEqual(mock.number("F0Tg"), 1200)

        try Fans.setSpeed(0, rpm: 3000)
        XCTAssertEqual(mock.number("F0Tg"), 3000)
    }

    func testSetManualModeWithoutModeKeyThrowsKeyNotFound() {
        mock.setNumber("F0Ac", type: "flt ", 1500)
        XCTAssertThrowsError(try Fans.setSpeed(0, rpm: 2000)) { error in
            guard case SMCError.keyNotFound = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
        }
    }

    func testSetAutoWritesZeroMode() throws {
        mock.addFan(0, mode: 1)
        try Fans.setAuto(0)
        XCTAssertEqual(mock.number("F0Md"), 0)
    }

    func testStickyModeWriteFallsBackToFtstAndRetries() throws {
        // First F0Md write is silently dropped (Apple Silicon firmware
        // behavior); the code must set Ftst=1 and retry until it sticks.
        mock.addFan(0)
        mock.setNumber("Ftst", type: "ui8 ", 0)
        mock.dropWrites["F0Md"] = 1

        try Fans.setManualMode(0, true)
        XCTAssertEqual(mock.number("F0Md"), 1)
        XCTAssertEqual(mock.number("Ftst"), 1, "Ftst should be raised before retrying")
        XCTAssertGreaterThanOrEqual(
            mock.writes.filter { $0.key == "F0Md" }.count, 2)
    }

    func testModeWriteThatNeverSticksThrowsWriteNotApplied() {
        // No Ftst key and every write dropped: after the retry loop the
        // failure must surface, not pass silently. (~4s: real retry cadence.)
        mock.addFan(0)
        mock.dropWrites["F0Md"] = Int.max

        XCTAssertThrowsError(try Fans.setManualMode(0, true)) { error in
            guard case SMCError.writeNotApplied(let key) = error else {
                return XCTFail("expected writeNotApplied, got \(error)")
            }
            XCTAssertEqual(key, "F0Md")
        }
    }

    func testSetAllAutoContinuesPastFailuresAndClearsFtst() {
        mock.setNumber("FNum", type: "flt ", 2)
        mock.addFan(0, mode: 1)
        mock.addFan(1, mode: 1)
        mock.setNumber("Ftst", type: "ui8 ", 1)
        mock.failWrites = ["F0Md"]

        // Fan 0 fails, but fan 1 must still be returned to auto and Ftst
        // cleared; the first error is rethrown at the end.
        XCTAssertThrowsError(try Fans.setAllAuto())
        XCTAssertEqual(mock.number("F1Md"), 0)
        XCTAssertEqual(mock.number("Ftst"), 0)
    }

    func testSetAllAutoSucceedsAndClearsFtst() throws {
        mock.setNumber("FNum", type: "flt ", 2)
        mock.addFan(0, mode: 1)
        mock.addFan(1, mode: 1)
        mock.setNumber("Ftst", type: "ui8 ", 1)

        try Fans.setAllAuto()
        XCTAssertEqual(mock.number("F0Md"), 0)
        XCTAssertEqual(mock.number("F1Md"), 0)
        XCTAssertEqual(mock.number("Ftst"), 0)
    }

    // MARK: - FanStatus model

    func testFanStatusCodableRoundTrip() throws {
        let original = FanStatus(
            id: 1, name: "Exhaust", actualRPM: 2450.5, minRPM: 1200,
            maxRPM: 6300, targetRPM: 2500, manual: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanStatus.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFanStatusJSONFieldNamesAreStable() throws {
        // fanctl's JSON output is consumed externally; field names are API.
        let st = FanStatus(id: 0, name: "Left", actualRPM: 1, minRPM: 2,
                           maxRPM: 3, targetRPM: 4, manual: false)
        let json = try XCTUnwrap(String(
            data: JSONEncoder().encode(st), encoding: .utf8))
        for field in ["id", "name", "actualRPM", "minRPM", "maxRPM",
                      "targetRPM", "manual"] {
            XCTAssertTrue(json.contains("\"\(field)\""), "missing \(field)")
        }
    }
}
