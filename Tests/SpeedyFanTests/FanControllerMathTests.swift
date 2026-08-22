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

    // MARK: - Manual-target reconciliation

    private func target(current: Double?, manual: Bool, target: Double,
                        actual: Double = 2000,
                        writesInFlight: Bool = false) -> Double {
        FanController.reconciledTarget(
            current: current,
            fan: FanStatus(id: 0, name: "Fan", actualRPM: actual, minRPM: 1499,
                           maxRPM: 5348, targetRPM: target, manual: manual),
            writesInFlight: writesInFlight)
    }

    func testSeedsPinnedFanFromItsRealTarget() {
        XCTAssertEqual(target(current: nil, manual: true, target: 3424), 3424)
    }

    func testSeedsAutoFanFromItsCurrentSpeedClampedToMinimum() {
        XCTAssertEqual(target(current: nil, manual: false, target: 1522,
                              actual: 1530), 1530)
        // Parked (blades stopped): start a future manual gesture at minimum.
        XCTAssertEqual(target(current: nil, manual: true, target: 0,
                              actual: 0), 1499)
    }

    func testAdoptsAnExternalPinWhenIdle() {
        // The bug this exists for: app running with a stale cache, someone
        // runs `fanctl set` in a terminal — the slider must show the truth.
        XCTAssertEqual(target(current: 1530, manual: true, target: 3424), 3424)
    }

    func testKeepsTheCacheWhileOwnWritesAreInFlight() {
        // The cache is ahead of the hardware here; adopting the hardware's
        // old target would snap the slider backwards for a moment.
        XCTAssertEqual(target(current: 3000, manual: true, target: 2500,
                              writesInFlight: true), 3000)
    }

    func testUnpinnedFanKeepsItsRememberedManualSpeed() {
        // Deliberately sticky: switching back to Manual resumes the last
        // speed the user chose, not wherever the firmware happens to be.
        XCTAssertEqual(target(current: 4000, manual: false, target: 1522), 4000)
        // A parked fan (forced, target 0) is not a pin either.
        XCTAssertEqual(target(current: 4000, manual: true, target: 0), 4000)
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

    /// Defaults describe the steady state the older tests assumed: heat that
    /// has already lasted long enough to engage, and a boost old enough to be
    /// allowed to release.
    private func boost(pinned: Bool = false, armedTemp: Int? = 90,
                       hottest: Double? = 80,
                       hotFor: TimeInterval? = FanController.boostEngageDelay,
                       pinnedFor: TimeInterval? = FanController.boostMinimumHold)
    -> FanController.BoostAction {
        FanController.boostAction(pinned: pinned, armedTemp: armedTemp,
                                  hottest: hottest, hotFor: hotFor,
                                  pinnedFor: pinnedFor)
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

    // MARK: - Boost anti-flapping
    //
    // Real notification log from this machine, before these rules existed:
    //   10:59:15 engaged … 10:59:25 released   (10 s)
    //   11:03:39 engaged … 11:03:46 released   ( 7 s)
    // A die sensor spiking past the trigger for one poll was enough to run a
    // whole engage/release cycle, and each cycle posted two banners.

    func testMomentarySpikeDoesNotEngage() {
        // At the trigger, but only just arrived there.
        XCTAssertEqual(boost(hottest: 95, hotFor: 0), .hold)
        XCTAssertEqual(boost(hottest: 95, hotFor: 2), .hold)
        // Sensor not currently hot at all: no clock running.
        XCTAssertEqual(boost(hottest: 95, hotFor: nil), .hold)
    }

    func testSustainedHeatEngages() {
        XCTAssertEqual(
            boost(hottest: 95, hotFor: FanController.boostEngageDelay), .boost)
        XCTAssertEqual(boost(hottest: 95, hotFor: 600), .boost)
    }

    func testFreshBoostHoldsEvenOnceCool() {
        // Cool enough to release, but engaged seconds ago — this is exactly
        // the 7-second cycle from the log above.
        XCTAssertEqual(boost(pinned: true, hottest: 70, pinnedFor: 7), .hold)
        XCTAssertEqual(boost(pinned: true, hottest: 70,
                             pinnedFor: FanController.boostMinimumHold - 1), .hold)
    }

    func testBoostReleasesOnceTheMinimumHoldHasPassed() {
        XCTAssertEqual(boost(pinned: true, hottest: 70,
                             pinnedFor: FanController.boostMinimumHold), .release)
    }

    func testMinimumHoldNeverOutranksSafetyReleases() {
        // Losing the sensors, or the user switching the feature off, releases
        // immediately however fresh the boost is.
        XCTAssertEqual(boost(pinned: true, hottest: nil, pinnedFor: 1), .release)
        XCTAssertEqual(boost(pinned: true, armedTemp: nil, hottest: 100,
                             pinnedFor: 1), .release)
    }

    func testEngageDelaySpansSeveralSupervisionPolls() {
        // Supervision samples every 2 s; the delay has to cover enough polls
        // that one twitchy reading can't carry it.
        XCTAssertGreaterThanOrEqual(
            FanController.boostEngageDelay,
            FanController.failsafePollInterval * 4)
        // And a hold long enough that a cycle can't repeat within a minute.
        XCTAssertGreaterThanOrEqual(FanController.boostMinimumHold, 60)
    }

    // MARK: - Boost notification episodes

    // The anti-flapping rules above stopped the seconds-long cycles, but a
    // real workload still crosses the trigger again and again as it runs.
    // Log from this machine with those rules in place — every hold a genuine,
    // minimum-length one, and every pair another two banners:
    //   09:28:31 engaged … 09:29:32 released
    //   09:35:00 engaged … 09:36:01 released
    //   09:39:01 engaged … 09:40:58 released
    //   09:42:30 engaged … 09:43:31 released
    //   09:50:17 engaged … 09:51:43 released
    // One episode of work, twelve notifications.

    func testFirstEverBoostIsAlwaysAnEpisode() {
        XCTAssertTrue(FanController.startsBoostEpisode(lastActive: nil,
                                                       now: at(0)))
    }

    func testReEngagingSoonAfterIsTheSameEpisode() {
        // The 09:29:32 → 09:35:00 gap from the log: 5½ minutes, same workload.
        XCTAssertFalse(FanController.startsBoostEpisode(lastActive: at(0),
                                                        now: at(328)))
        XCTAssertFalse(FanController.startsBoostEpisode(
            lastActive: at(0), now: at(FanController.boostEpisodeGap - 1)))
    }

    func testEngagingAfterALongCoolSpellIsANewEpisode() {
        XCTAssertTrue(FanController.startsBoostEpisode(
            lastActive: at(0), now: at(FanController.boostEpisodeGap)))
        // 08:06:58 → 09:28:31 in the log: a different piece of work entirely.
        XCTAssertTrue(FanController.startsBoostEpisode(lastActive: at(0),
                                                       now: at(4893)))
    }

    func testTheLoggedBurstWouldAnnounceOnlyOnce() {
        // Replay the five cycles above, keeping the clock the way
        // enforceMaxBoost does: every engage and every hold marks the boost
        // active, so the gap is measured from when it last stopped.
        let cycles: [(engage: TimeInterval, release: TimeInterval)] = [
            (0, 61), (389, 450), (630, 747), (839, 900), (1306, 1392),
        ]
        var lastActive: Date?
        var announced = 0
        for cycle in cycles {
            if FanController.startsBoostEpisode(lastActive: lastActive,
                                                now: at(cycle.engage)) {
                announced += 1
            }
            lastActive = at(cycle.release)
        }
        XCTAssertEqual(announced, 1)
    }

    func testEpisodeGapOutlastsAWholeBoostCycle() {
        // Otherwise a single cycle could age out of its own episode and the
        // very next crossing would announce itself again.
        XCTAssertGreaterThan(FanController.boostEpisodeGap,
                             FanController.boostMinimumHold
                                + FanController.boostEngageDelay)
    }

    func testFailsafeTemperatureRangeIsBelowSensorPlausibilityCeiling() {
        // Sensors discards readings >= 120 as implausible; every allowed
        // failsafe threshold must be reachable by real readings.
        XCTAssertLessThan(AppSettings.failsafeTempRange.upperBound, 120)
        XCTAssertGreaterThan(AppSettings.failsafeTempRange.lowerBound, 70)
    }

    // MARK: - Stuck fan detection

    private func spinning(target: Double, actual: Double,
                          min: Double = 1499) -> FanStatus {
        FanStatus(id: 0, name: "Fan", actualRPM: actual, minRPM: min,
                  maxRPM: 5348, targetRPM: target, manual: true)
    }

    func testCommandedButMotionlessFanIsStalled() {
        XCTAssertTrue(FanController.isStalled(spinning(target: 3000, actual: 0)))
        XCTAssertTrue(FanController.isStalled(spinning(target: 1499, actual: 50)))
    }

    func testParkedFanIsNotStalled() {
        // Target 0 is the firmware parking a fan on purpose.
        XCTAssertFalse(FanController.isStalled(spinning(target: 0, actual: 0)))
    }

    func testTurningFanIsNotStalled() {
        XCTAssertFalse(FanController.isStalled(spinning(target: 3000, actual: 2900)))
        // Even well short of the target: turning at all means not stuck.
        XCTAssertFalse(FanController.isStalled(spinning(target: 3000, actual: 400)))
    }

    func testTinyCommandsCannotReadAsStalls() {
        // With an unreadable minimum (0), a sub-floor target must not count:
        // "not spinning" is meaningless when barely asked to spin.
        XCTAssertFalse(FanController.isStalled(
            spinning(target: 50, actual: 0, min: 0)))
        XCTAssertTrue(FanController.isStalled(
            spinning(target: 2000, actual: 0, min: 0)))
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testStallEpisodeStartsQuietly() {
        let (record, alert) = FanController.stallStep(nil, stalled: true, at: at(0))
        XCTAssertEqual(record, FanController.StallRecord(
            since: at(0), lastSeen: at(0), alerted: false))
        XCTAssertFalse(alert)
    }

    func testStallAlertsOnceAfterThreshold() {
        var (record, alert) = FanController.stallStep(nil, stalled: true, at: at(0))
        (record, alert) = FanController.stallStep(record, stalled: true, at: at(10))
        XCTAssertFalse(alert)  // 10 s in: could still be spin-up
        (record, alert) = FanController.stallStep(record, stalled: true, at: at(30))
        XCTAssertTrue(alert)   // threshold reached
        (record, alert) = FanController.stallStep(record, stalled: true, at: at(50))
        XCTAssertFalse(alert)  // one alert per episode
        XCTAssertEqual(record?.alerted, true)
    }

    func testHealthyFanClearsTheEpisode() {
        var (record, _) = FanController.stallStep(nil, stalled: true, at: at(0))
        (record, _) = FanController.stallStep(record, stalled: false, at: at(10))
        XCTAssertNil(record)
        // A later stall is a fresh episode with a fresh alert.
        let again = FanController.stallStep(record, stalled: true, at: at(20))
        XCTAssertEqual(again.record?.since, at(20))
    }

    func testObservationGapRestartsTheClock() {
        // 25 s observed stalled, then a hole (panel closed, sleep): the
        // stall clock must restart, not count time nobody measured.
        var (record, alert) = FanController.stallStep(nil, stalled: true, at: at(0))
        (record, alert) = FanController.stallStep(record, stalled: true, at: at(25))
        XCTAssertFalse(alert)
        (record, alert) = FanController.stallStep(record, stalled: true, at: at(100))
        XCTAssertFalse(alert)
        XCTAssertEqual(record?.since, at(100))
    }

    func testStallGapExceedsTheSlowestPollingCadence() {
        // Menu-bar-only polling refreshes as slowly as every 20 s; those
        // observations must still chain into one episode.
        XCTAssertGreaterThan(FanController.stuckObservationGap,
                             TimeInterval(AppSettings.refreshSecondsRange.upperBound))
    }

    func testStallAlertWaitsOutSpinUp() {
        // A healthy fan reaches its minimum within a few seconds of being
        // commanded; the alert threshold must comfortably exceed that.
        XCTAssertGreaterThanOrEqual(FanController.stuckAlertAfter, 15)
    }

}
