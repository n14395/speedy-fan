// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SMCCore

/// Temperature sensor discovery and the hottest-sensor summary.
final class SensorsTests: XCTestCase {
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

    func testTemperatureKeysFiltersByPrefixTypeAndRange() {
        mock.setNumber("TC0P", type: "flt ", 55)      // keep
        mock.setSp78("Ts0P", 45.5)                    // keep (sp78 also valid)
        mock.setNumber("TLOW", type: "flt ", 5)       // reject: <= 10
        mock.setNumber("THOT", type: "flt ", 130)     // reject: >= 120
        mock.setNumber("TFLG", type: "ui8 ", 60)      // reject: wrong type
        mock.setNumber("PC0C", type: "flt ", 50)      // reject: not a T key
        mock.setNumber("FNum", type: "flt ", 1)       // reject: not a T key

        XCTAssertEqual(Sensors.temperatureKeys(), ["TC0P", "Ts0P"])
    }

    func testTemperatureKeysEmptyWhenSMCUnavailable() {
        XCTAssertEqual(Sensors.temperatureKeys(), [])
    }

    func testHottestPicksMaximum() {
        mock.setNumber("TC0P", type: "flt ", 55)
        mock.setNumber("TG0P", type: "flt ", 71.5)
        XCTAssertEqual(Sensors.hottest(["TC0P", "TG0P"]), 71.5)
    }

    func testHottestIgnoresValuesThatWentOutOfRange() {
        // A sensor that was plausible at discovery can go bad later; stale
        // garbage must not win the max.
        mock.setNumber("TC0P", type: "flt ", 200)
        mock.setNumber("TG0P", type: "flt ", 64)
        XCTAssertEqual(Sensors.hottest(["TC0P", "TG0P"]), 64)
    }

    func testHottestNilForEmptyOrMissingKeys() {
        XCTAssertNil(Sensors.hottest([]))
        XCTAssertNil(Sensors.hottest(["TC0P"]))
    }

    func testReadingsReturnsPlausibleValuesPerKey() {
        mock.setNumber("TC0P", type: "flt ", 55)
        mock.setNumber("TG0P", type: "flt ", 71.5)
        mock.setNumber("TBAD", type: "flt ", 200)  // implausible now
        let readings = Sensors.readings(["TC0P", "TG0P", "TBAD", "TGONE"])
        XCTAssertEqual(readings, [
            SensorReading(key: "TC0P", value: 55),
            SensorReading(key: "TG0P", value: 71.5),
        ])
    }
}
