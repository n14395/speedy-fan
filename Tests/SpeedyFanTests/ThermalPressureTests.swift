import XCTest
import SwiftUI
@testable import SpeedyFan

/// Display mapping for macOS's thermal pressure verdict.
final class ThermalPressureTests: XCTestCase {

    func testEveryStateHasALabel() {
        XCTAssertEqual(ThermalPressure.label(.nominal), "Nominal")
        XCTAssertEqual(ThermalPressure.label(.fair), "Fair")
        XCTAssertEqual(ThermalPressure.label(.serious), "Serious")
        XCTAssertEqual(ThermalPressure.label(.critical), "Critical")
    }

    func testOnlyThrottlingStatesGetColor() {
        // Nominal and fair are everyday states; color starts where macOS
        // starts throttling.
        XCTAssertNil(ThermalPressure.tint(.nominal))
        XCTAssertNil(ThermalPressure.tint(.fair))
        XCTAssertEqual(ThermalPressure.tint(.serious), .orange)
        XCTAssertEqual(ThermalPressure.tint(.critical), .red)
    }
}
