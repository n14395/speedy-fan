// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SMCCore

/// Pure value coding: four-char codes, the 80-byte param struct contract,
/// and every SMC data type the app decodes or encodes.
final class SMCCodingTests: XCTestCase {

    // MARK: - Four-char codes

    func testFourCCEncodesBigEndianASCII() {
        XCTAssertEqual(fourCC("FNum"), 0x464E_756D)
        XCTAssertEqual(fourCC("#KEY"), 0x234B_4559)
    }

    func testFourCCUsesOnlyFirstFourCharacters() {
        XCTAssertEqual(fourCC("FNumEXTRA"), fourCC("FNum"))
    }

    func testFourCCRoundTrip() {
        for key in ["FNum", "F0Ac", "Ftst", "{fds", "sp78", "#KEY"] {
            XCTAssertEqual(fourCCString(fourCC(key)), key)
        }
    }

    // MARK: - SMCParamStruct layout

    func testParamStructIsExactly80Bytes() {
        // The AppleSMC kernel service rejects any other size; this is the
        // wire contract everything else depends on.
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
    }

    // MARK: - Decoding

    func decode(_ type: String, _ bytes: [UInt8]) throws -> Double {
        try SMC.decode(type: type, bytes: bytes, key: "TEST")
    }

    func testDecodeUI8AndFlag() throws {
        XCTAssertEqual(try decode("ui8 ", [0]), 0)
        XCTAssertEqual(try decode("ui8 ", [255]), 255)
        XCTAssertEqual(try decode("flag", [1]), 1)
        XCTAssertEqual(try decode("si8 ", [7]), 7)
    }

    func testDecodeUI16IsBigEndian() throws {
        XCTAssertEqual(try decode("ui16", [0x12, 0x34]), 0x1234)
    }

    func testDecodeUI32IsBigEndian() throws {
        XCTAssertEqual(try decode("ui32", [0x00, 0x01, 0x00, 0x00]), 65536)
    }

    func testDecodeFltIsNativeLittleEndianFloat() throws {
        let bytes = withUnsafeBytes(of: Float32(1234.5)) { Array($0) }
        XCTAssertEqual(try decode("flt ", bytes), 1234.5, accuracy: 0.001)
    }

    func testDecodeFpe2() throws {
        // fpe2: unsigned fixed-point, value = raw16 / 4.
        // 1200 RPM -> raw 4800 = 0x12C0 -> bytes [0x12, 0xC0]
        XCTAssertEqual(try decode("fpe2", [0x12, 0xC0]), 1200)
        XCTAssertEqual(try decode("fpe2", [0x00, 0x00]), 0)
    }

    func testDecodeSp78IncludingNegative() throws {
        // sp78: signed fixed-point /256. 45.5C -> 0x2D80; -1.5C -> 0xFE80.
        XCTAssertEqual(try decode("sp78", [0x2D, 0x80]), 45.5)
        XCTAssertEqual(try decode("sp78", [0xFE, 0x80]), -1.5)
    }

    func testDecodeShortBufferThrows() {
        XCTAssertThrowsError(try decode("ui8 ", []))
        XCTAssertThrowsError(try decode("ui16", [1]))
        XCTAssertThrowsError(try decode("ui32", [1, 2, 3]))
        XCTAssertThrowsError(try decode("flt ", [1, 2, 3]))
        XCTAssertThrowsError(try decode("fpe2", [1]))
        XCTAssertThrowsError(try decode("sp78", [1]))
    }

    func testDecodeUnknownTypeThrowsBadData() {
        XCTAssertThrowsError(try decode("ch8*", [65, 66])) { error in
            guard case SMCError.badData(let what) = error else {
                return XCTFail("expected badData, got \(error)")
            }
            XCTAssertTrue(what.contains("TEST"))
            XCTAssertTrue(what.contains("ch8*"))
        }
    }

    // MARK: - Encoding

    func encode(_ type: String, _ value: Double) throws -> [UInt8] {
        try SMC.encode(type: type, value: value, key: "TEST")
    }

    func testEncodeUI8ClampsToByteRange() throws {
        XCTAssertEqual(try encode("ui8 ", -5), [0])
        XCTAssertEqual(try encode("ui8 ", 300), [255])
        XCTAssertEqual(try encode("ui8 ", 1), [1])
    }

    func testEncodeFltRoundTrips() throws {
        let bytes = try encode("flt ", 3456.0)
        XCTAssertEqual(bytes.count, 4)
        XCTAssertEqual(try decode("flt ", bytes), 3456.0)
    }

    func testEncodeFpe2RoundTripsAndClamps() throws {
        XCTAssertEqual(try decode("fpe2", try encode("fpe2", 1200)), 1200)
        XCTAssertEqual(try decode("fpe2", try encode("fpe2", 0)), 0)
        // Clamped to the 14-bit maximum.
        XCTAssertEqual(try decode("fpe2", try encode("fpe2", 99999)), 16383)
        XCTAssertEqual(try decode("fpe2", try encode("fpe2", -100)), 0)
    }

    func testEncodeUnsupportedTypeThrows() {
        // ui16/ui32/sp78 are read-only in this app; writes reject them.
        XCTAssertThrowsError(try encode("ui16", 1))
        XCTAssertThrowsError(try encode("sp78", 40))
    }

    // MARK: - Derived typed access via the protocol

    func testReadNumberUsesKeyTypeFromKeyInfo() throws {
        let mock = MockSMC()
        mock.setNumber("F0Ac", type: "flt ", 1520)
        XCTAssertEqual(try mock.readNumber("F0Ac"), 1520)
    }

    func testWriteNumberEncodesPerKeyType() throws {
        let mock = MockSMC()
        mock.setNumber("F0Md", type: "ui8 ", 0)
        try mock.writeNumber("F0Md", 1)
        XCTAssertEqual(mock.store["F0Md"]?.bytes, [1])
    }

    func testReadNumberMissingKeyThrowsKeyNotFound() {
        let mock = MockSMC()
        XCTAssertThrowsError(try mock.readNumber("Nope")) { error in
            guard case SMCError.keyNotFound(let key) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key, "Nope")
        }
    }

    func testKeyCountReflectsStoredKeys() throws {
        let mock = MockSMC()
        XCTAssertEqual(try mock.keyCount(), 0)
        mock.setNumber("FNum", type: "flt ", 2)
        mock.setNumber("F0Ac", type: "flt ", 1000)
        XCTAssertEqual(try mock.keyCount(), 2)
    }

    // MARK: - Error descriptions

    func testErrorDescriptionsMentionTheKey() {
        XCTAssertTrue(SMCError.keyNotFound("F9Md").description.contains("F9Md"))
        XCTAssertTrue(SMCError.writeNotApplied("F0Md").description.contains("F0Md"))
        XCTAssertTrue(SMCError.smcResult("Ftst", 132).description.contains("Ftst"))
    }
}
