import XCTest
@testable import SpeedyFan

/// Sensor-key naming: chip-generation tables, shared Apple Silicon keys,
/// classic keys, and the raw-key fallback.
final class SensorNameTests: XCTestCase {

    func testGenerationParsesMSeriesBrandStrings() {
        XCTAssertEqual(SensorName.generation(brandString: "Apple M1"), 1)
        XCTAssertEqual(SensorName.generation(brandString: "Apple M1 Max"), 1)
        XCTAssertEqual(SensorName.generation(brandString: "Apple M2 Pro"), 2)
        XCTAssertEqual(SensorName.generation(brandString: "Apple M4 Ultra"), 4)
        // Future generations parse too; they just have no table yet.
        XCTAssertEqual(SensorName.generation(brandString: "Apple M9"), 9)
    }

    func testGenerationNilOnIntel() {
        XCTAssertNil(SensorName.generation(
            brandString: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"))
        XCTAssertNil(SensorName.generation(brandString: ""))
        // "M" alone or non-numeric suffixes are not a generation.
        XCTAssertNil(SensorName.generation(brandString: "Apple M Ultra"))
    }

    func testSameKeyMeansDifferentSensorsOnDifferentGenerations() {
        // The reason the tables are per-generation at all.
        XCTAssertEqual(SensorName.label(for: "Tp09", generation: 1),
                       "CPU efficiency core 1")
        XCTAssertEqual(SensorName.label(for: "Tp09", generation: 2),
                       "CPU performance core 3")
        XCTAssertEqual(SensorName.label(for: "Tp09", generation: 4),
                       "CPU performance core 3")
    }

    func testAppleSiliconSharedKeysApplyOnEveryGeneration() {
        XCTAssertEqual(SensorName.label(for: "TaLP", generation: 1), "Airflow left")
        XCTAssertEqual(SensorName.label(for: "TH0x", generation: 3), "NAND")
        // Even ones we have no per-chip table for.
        XCTAssertEqual(SensorName.label(for: "TaRF", generation: 9), "Airflow right")
    }

    func testClassicKeysApplyEverywhere() {
        XCTAssertEqual(SensorName.label(for: "TC0P", generation: nil), "CPU Proximity")
        XCTAssertEqual(SensorName.label(for: "TC0P", generation: 1), "CPU Proximity")
        XCTAssertEqual(SensorName.label(for: "TA0P", generation: 2), "Ambient")
    }

    func testIntelOnlyNamesAreNotAppliedOnAppleSilicon() {
        // This M1 Max exposes a Th0H too, but its classic "Heatpipe" meaning
        // is only attested on Intel: better a raw key than a wrong name.
        XCTAssertEqual(SensorName.label(for: "Th0H", generation: nil), "Heatpipe 1")
        XCTAssertEqual(SensorName.label(for: "Th0H", generation: 1), "Th0H")
    }

    func testUnknownKeysFallBackToPrefixThenRaw() {
        // Real keys from this machine that no community table names.
        XCTAssertEqual(SensorName.label(for: "Tp0c", generation: 1), "CPU (Tp0c)")
        XCTAssertEqual(SensorName.label(for: "Tg04", generation: 1), "GPU (Tg04)")
        XCTAssertEqual(SensorName.label(for: "TCMz", generation: 1), "TCMz")
        XCTAssertEqual(SensorName.label(for: "TXYZ", generation: nil), "TXYZ")
    }
}
