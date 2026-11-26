import CoreGraphics
import XCTest
@testable import OpenYoink

final class MouseShakeMonitorTests: XCTestCase {
    // MARK: - Helpers

    /// Feeds x coordinates at a fixed step (constant y); returns the hit indices.
    private func hitIndices(xs: [CGFloat],
                            step: TimeInterval,
                            parameters: ShakeDetector.Parameters) -> [Int] {
        var detector = ShakeDetector(parameters: parameters)
        var hits: [Int] = []
        for (index, x) in xs.enumerated() {
            if detector.addSample(CGPoint(x: x, y: 500), at: TimeInterval(index) * step) {
                hits.append(index)
            }
        }
        return hits
    }

    /// Back and forth between two x values (a typical shake).
    private func alternating(_ a: CGFloat, _ b: CGFloat, count: Int) -> [CGFloat] {
        (0..<count).map { $0.isMultiple(of: 2) ? a : b }
    }

    // MARK: - Hits

    func testTypicalShake_triggers() {

        let hits = hitIndices(xs: alternating(0, 40, count: 12),
                              step: 0.06,
                              parameters: TriggerSensitivity.medium.shakeParameters)
        XCTAssertEqual(hits, [6])
    }

    // MARK: - Non-gestures

    func testStraightLine_doesNotTrigger() {
        // A straight line at constant speed never reverses.
        let xs = (0..<200).map { CGFloat($0) * 8 }
        XCTAssertTrue(hitIndices(xs: xs, step: 0.016,
                                 parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
    }

    func testSlowWobble_doesNotTrigger() {
        // A slow wobble: long enough segments, but reversals 0.6 s apart, so any
        // 1.5 s window holds at most 3 (4 need at least 1.8 s), short of high's 4.
        XCTAssertTrue(hitIndices(xs: alternating(0, 50, count: 12),
                                 step: 0.6,
                                 parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
    }

    func testSmallJitter_doesNotTrigger() {
        // Jitter: 3 pt is far below the minimum segment; the direction never confirms.
        XCTAssertTrue(hitIndices(xs: alternating(0, 3, count: 150),
                                 step: 0.02,
                                 parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
    }

    func testVerticalMovement_doesNotTrigger() {
        // Vertical only: no x movement, nothing to judge.
        var detector = ShakeDetector(parameters: TriggerSensitivity.high.shakeParameters)
        var fired = false
        for index in 0..<50 {
            let y: CGFloat = index.isMultiple(of: 2) ? 0 : 200
            fired = detector.addSample(CGPoint(x: 100, y: y),
                                       at: TimeInterval(index) * 0.05) || fired
        }
        XCTAssertFalse(fired)
    }

    // MARK: - Thresholds

    func testSegmentBelowMinDistance_doesNotTrigger() {
        // Segments of 19 < 20: every turn resets the accumulator; the direction never confirms.
        let parameters = ShakeDetector.Parameters(window: 2.0, requiredReversals: 3,
                                                  minSegmentDistance: 20)
        XCTAssertTrue(hitIndices(xs: alternating(0, 19, count: 40),
                                 step: 0.05, parameters: parameters).isEmpty)
    }

    func testSegmentExactlyAtMinDistance_triggers() {

        let parameters = ShakeDetector.Parameters(window: 2.0, requiredReversals: 3,
                                                  minSegmentDistance: 20)
        XCTAssertEqual(hitIndices(xs: alternating(0, 20, count: 10),
                                  step: 0.05, parameters: parameters), [4, 8])
    }

    func testReversalsSpreadBeyondWindow_doNotAccumulate() {
        // 1.0 s window, 4 reversals needed: 3 quick reversals, a 2 s pause, 3 more.
        // The window prunes the first batch, so 4 are never reached.
        let parameters = ShakeDetector.Parameters(window: 1.0, requiredReversals: 4,
                                                  minSegmentDistance: 10)
        var detector = ShakeDetector(parameters: parameters)
        var fired = false
        var time: TimeInterval = 0
        var x: CGFloat = 0

        func feed(_ steps: Int) {
            for _ in 0..<steps {
                time += 0.05
                x = (x == 0) ? 20 : 0
                fired = detector.addSample(CGPoint(x: x, y: 500), at: time) || fired
            }
        }

        feed(4) // confirm a direction + 3 reversals (t=0.05...0.20)
        time += 2.0 // pause (no movement means no samples; just advance the clock)
        feed(3) // 3 more reversals: the old ones expired, at most 3 < 4 in the window
        XCTAssertFalse(fired)
    }

    // MARK: - Sensitivity tiers

    func testSensitivityTiers_shortSegmentsTriggerHighOnly() {
        // 14 pt segments, a turn every 70 ms: high (12 pt / 4 / 1.5 s) hits;
        // medium (18 pt) never confirms a direction; neither does low.
        let xs = alternating(0, 14, count: 20)
        XCTAssertFalse(hitIndices(xs: xs, step: 0.07,
                                  parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
        XCTAssertTrue(hitIndices(xs: xs, step: 0.07,
                                 parameters: TriggerSensitivity.medium.shakeParameters).isEmpty)
        XCTAssertTrue(hitIndices(xs: xs, step: 0.07,
                                 parameters: TriggerSensitivity.low.shakeParameters).isEmpty)
    }

    func testSensitivityTiers_fiveReversalsTriggerMediumButNotLow() {
        // 30 pt segments, a step every 110 ms, 5 reversals (t ≤ 0.66 s): medium
        // needs 5 (1.2 s window) and hits; low needs 6 and doesn't.
        let xs = alternating(0, 30, count: 7)
        XCTAssertEqual(hitIndices(xs: xs, step: 0.11,
                                  parameters: TriggerSensitivity.medium.shakeParameters), [6])
        XCTAssertTrue(hitIndices(xs: xs, step: 0.11,
                                 parameters: TriggerSensitivity.low.shakeParameters).isEmpty)
    }

    // MARK: - State reset after hit

    func testHitResetsState_nextGestureMustRequalify() {
        // The detector resets after a hit: shaking on hits again, but only after
        // a fresh set of reversals (hits 6 samples apart, not on every sample).
        let hits = hitIndices(xs: alternating(0, 40, count: 14),
                              step: 0.06,
                              parameters: TriggerSensitivity.medium.shakeParameters)
        XCTAssertEqual(hits, [6, 12])
    }
}
