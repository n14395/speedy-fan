import XCTest
import SMCCore
@testable import SpeedyFan

/// Pure math backing the linked-fans slider. (FanController's side-effecting
/// paths run the privileged helper and are deliberately not driven by tests.)
final class FanControllerMathTests: XCTestCase {

    private func fan(actual: Double = 2400, min: Double = 1200,
                     max: Double = 6000) -> FanStatus {
        FanStatus(id: 0, name: "Fan 1", actualRPM: actual, minRPM: min,
                  maxRPM: max, targetRPM: 0, manual: false)
    }

    func testCurrentFractionWithinRange() throws {
        let f = try XCTUnwrap(FanController.currentFraction(of: fan()))
        XCTAssertEqual(f, 0.25, accuracy: 0.0001)  // (2400-1200)/(6000-1200)
    }

    func testCurrentFractionAtBounds() {
        XCTAssertEqual(FanController.currentFraction(of: fan(actual: 1200)), 0)
        XCTAssertEqual(FanController.currentFraction(of: fan(actual: 6000)), 1)
    }

    func testCurrentFractionNilForDegenerateRange() {
        XCTAssertNil(FanController.currentFraction(of: fan(min: 3000, max: 3000)))
        XCTAssertNil(FanController.currentFraction(of: fan(min: 3000, max: 2000)))
    }

    func testLinkedRPMMapsFractionOntoFanRange() {
        XCTAssertEqual(FanController.linkedRPM(0, for: fan()), 1200)
        XCTAssertEqual(FanController.linkedRPM(1, for: fan()), 6000)
        XCTAssertEqual(FanController.linkedRPM(0.5, for: fan()), 3600)
    }

    func testLinkedRPMClampsFraction() {
        XCTAssertEqual(FanController.linkedRPM(-0.5, for: fan()), 1200)
        XCTAssertEqual(FanController.linkedRPM(1.5, for: fan()), 6000)
    }

    func testLinkedRPMRoundTripsThroughCurrentFraction() throws {
        let f = fan(actual: 3210)
        let fraction = try XCTUnwrap(FanController.currentFraction(of: f))
        XCTAssertEqual(FanController.linkedRPM(fraction, for: f), 3210,
                       accuracy: 0.0001)
    }

    func testFanModeRawValuesMatchSMCModeValues() {
        // 0/1 are what the firmware's F<n>Md key stores.
        XCTAssertEqual(FanMode.auto.rawValue, 0)
        XCTAssertEqual(FanMode.manual.rawValue, 1)
    }

    // MARK: - Pinned vs. parked

    private func status(manual: Bool, target: Double, min: Double = 1499,
                        max: Double = 5348) -> FanStatus {
        FanStatus(id: 0, name: "Fan", actualRPM: target, minRPM: min,
                  maxRPM: max, targetRPM: target, manual: manual)
    }

    func testForcedFanAtAPlausibleTargetIsPinned() {
        XCTAssertTrue(FanController.isPinned(status(manual: true, target: 3000)))
        // Exactly at the fan's own minimum is a legitimate pin.
        XCTAssertTrue(FanController.isPinned(status(manual: true, target: 1499)))
    }

    func testParkedFanIsNotPinned() {
        // This Mac's firmware parks a fan by forcing it to 0 — below the
        // fan's minimum, which setSpeed can never produce. Reading that as
        // manual control is what showed "Manual, 0%" after waking.
        XCTAssertFalse(FanController.isPinned(status(manual: true, target: 0)))
        XCTAssertFalse(FanController.isPinned(status(manual: true, target: 900)))
    }

    func testAutomaticFanIsNeverPinned() {
        XCTAssertFalse(FanController.isPinned(status(manual: false, target: 3000)))
    }

    func testParkedFanWithNoReadableMinimumIsNotPinned() {
        // A failed F<n>Mn read reports 0; target 0 must still not count.
        XCTAssertFalse(FanController.isPinned(
            status(manual: true, target: 0, min: 0)))
        XCTAssertTrue(FanController.isPinned(
            status(manual: true, target: 2000, min: 0)))
    }

    // MARK: - Polling policy

    private func interval(menuVisible: Bool = false,
                          anyManual: Bool = false,
                          boostArmed: Bool = false) -> TimeInterval? {
        FanController.pollInterval(menuVisible: menuVisible,
                                   anyManual: anyManual,
                                   boostArmed: boostArmed)
    }

    func testNoPollingWhenNothingNeedsData() {
        XCTAssertNil(interval())
    }

    func testOpenMenuPollsEverySecond() {
        XCTAssertEqual(interval(menuVisible: true), 1)
    }

    func testMenuBarCadenceIsNotFoldedIntoTheHardwarePoll() {
        // The menu bar runs its own timer at exactly the user's interval, so
        // nothing here may depend on it. Folding it in made the menu bar
        // inherit whichever consumer was fastest — the bug where an armed
        // boost dragged a 5 s menu bar reading down to the 2 s supervision
        // cadence.
        XCTAssertNil(interval())
        XCTAssertEqual(interval(boostArmed: true),
                       FanController.failsafePollInterval)
        XCTAssertEqual(interval(anyManual: true),
                       FanController.failsafePollInterval)
        XCTAssertEqual(interval(menuVisible: true), 1)
    }

    func testArmedBoostKeepsSupervisionPolling() {
        XCTAssertEqual(interval(boostArmed: true),
                       FanController.failsafePollInterval)
        XCTAssertNil(interval(boostArmed: false))
    }

    func testManualModeKeepsFailsafePolling() {
        // Even with nothing on screen the thermal failsafe needs readings.
        XCTAssertEqual(interval(anyManual: true),
                       FanController.failsafePollInterval)
        // The open panel is the only thing that polls faster.
        XCTAssertEqual(interval(menuVisible: true, anyManual: true), 1)
    }

    // MARK: - Sensor trends

    func testTrendNeedsAFullDegree() {
        XCTAssertEqual(FanController.trend(from: 70, to: 71.5), .rising)
        XCTAssertEqual(FanController.trend(from: 70, to: 68), .falling)
        // Sub-threshold movement is sensor noise, not a trend.
        XCTAssertEqual(FanController.trend(from: 70, to: 70.9), .steady)
        XCTAssertEqual(FanController.trend(from: 70, to: 69.1), .steady)
        XCTAssertEqual(FanController.trend(from: 70, to: 70), .steady)
    }

    func testTrendThresholdIsInclusive() {
        XCTAssertEqual(FanController.trend(from: 70, to: 71), .rising)
        XCTAssertEqual(FanController.trend(from: 71, to: 70), .falling)
    }

    // MARK: - Temperature history

    private func sample(at seconds: TimeInterval,
                        value: Double = 70) -> FanController.TempSample {
        FanController.TempSample(
            time: Date(timeIntervalSinceReferenceDate: seconds), value: value)
    }

    func testHistoryTrimsToTheWindow() {
        let history = [sample(at: 0), sample(at: 300), sample(at: 550)]
        let kept = FanController.appending(sample(at: 620), to: history,
                                           window: 600)
        // t=0 is 620 s before the new sample — outside a 600 s window.
        XCTAssertEqual(kept, [sample(at: 300), sample(at: 550),
                              sample(at: 620)])
    }

    func testHistoryKeepsSamplesExactlyAtTheWindowEdge() {
        let kept = FanController.appending(sample(at: 600),
                                           to: [sample(at: 0)], window: 600)
        XCTAssertEqual(kept.count, 2)
    }

    func testGapSegmentsSplitWhereObservationStopped() {
        // 1 s cadence, a 100 s hole, then 1 s cadence again.
        let history = [sample(at: 0), sample(at: 1), sample(at: 2),
                       sample(at: 102), sample(at: 103)]
        let segments = FanController.gapSegments(history, gap: 30)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, 3)
        XCTAssertEqual(segments[1].count, 2)
    }

    func testGapSegmentsKeepContinuousHistoryWhole() {
        let history = [sample(at: 0), sample(at: 20), sample(at: 40)]
        XCTAssertEqual(FanController.gapSegments(history, gap: 30).count, 1)
    }

    func testGapSegmentsLoneSampleSurvives() {
        // A single observation between two holes must still be drawable.
        let history = [sample(at: 0), sample(at: 100), sample(at: 200)]
        let segments = FanController.gapSegments(history, gap: 30)
        XCTAssertEqual(segments, [[sample(at: 0)], [sample(at: 100)],
                                  [sample(at: 200)]])
    }

    func testHistoryGapExceedsTheSlowestPollingCadence() {
        // The slowest legitimate sample spacing is the 20 s max menu bar
        // interval; the gap threshold must not cut a continuous record.
        XCTAssertGreaterThan(FanController.historyGap,
                             TimeInterval(AppSettings.refreshSecondsRange.upperBound))
    }

    // MARK: - Maximum fans at temperature

    private func boost(pinned: Bool = false, armedTemp: Int? = 90,
                       hottest: Double? = 80) -> FanController.BoostAction {
        FanController.boostAction(pinned: pinned, armedTemp: armedTemp,
                                  hottest: hottest)
    }

    func testBoostFiresAtOrAboveArmedTemp() {
        XCTAssertEqual(boost(hottest: 90), .boost)
        XCTAssertEqual(boost(hottest: 97), .boost)
        XCTAssertEqual(boost(hottest: 89), .hold)
    }

    func testBoostDoesNothingWhenOffOrBlind() {
        XCTAssertEqual(boost(armedTemp: nil, hottest: 100), .hold)
        XCTAssertEqual(boost(hottest: nil), .hold)
    }

    func testDisarmingWhileBoostedReleases() {
        XCTAssertEqual(boost(pinned: true, armedTemp: nil, hottest: 100), .release)
    }

    func testBoostedHoldsThroughHysteresisAndReleasesWhenCool() {
        XCTAssertEqual(boost(pinned: true, hottest: 95), .hold)
        XCTAssertEqual(boost(pinned: true, hottest: 81), .hold)
        XCTAssertEqual(boost(pinned: true, hottest: 80), .release)
        XCTAssertEqual(boost(pinned: true, hottest: 70), .release)
    }

    func testBoostedReleasesWhenBlind() {
        // Losing the sensors while boosted must release, not hold blind.
        XCTAssertEqual(boost(pinned: true, hottest: nil), .release)
    }

    func testBoostHysteresisMarginIsPositive() {
        XCTAssertGreaterThan(FanController.boostReleaseMargin, 0)
    }

    func testFailsafeTemperatureRangeIsBelowSensorPlausibilityCeiling() {
        // Sensors discards readings >= 120 as implausible; every allowed
        // failsafe threshold must be reachable by real readings.
        XCTAssertLessThan(AppSettings.failsafeTempRange.upperBound, 120)
        XCTAssertGreaterThan(AppSettings.failsafeTempRange.lowerBound, 70)
    }

}
