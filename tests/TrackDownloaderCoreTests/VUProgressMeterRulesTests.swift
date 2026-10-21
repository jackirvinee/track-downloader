import TrackDownloaderCore
import XCTest

final class VUProgressMeterRulesTests: XCTestCase {
    func testNormalizesFractionsForDisplayAndFill() {
        XCTAssertEqual(VUProgressMeterRules.normalizedFraction(.nan), 0)
        XCTAssertEqual(VUProgressMeterRules.normalizedFraction(.infinity), 0)
        XCTAssertEqual(VUProgressMeterRules.normalizedFraction(-.infinity), 0)
        XCTAssertEqual(VUProgressMeterRules.normalizedFraction(-0.25), 0)
        XCTAssertEqual(VUProgressMeterRules.normalizedFraction(0.68), 0.68)
        XCTAssertEqual(VUProgressMeterRules.normalizedFraction(1.25), 1)
    }

    func testDeterminateFillUsesAContiguousTwentySixSegmentRail() {
        XCTAssertEqual(VUProgressMeterRules.filledSegmentCount(for: 0), 0)
        XCTAssertEqual(VUProgressMeterRules.filledSegmentCount(for: 0.68), 17)
        XCTAssertEqual(VUProgressMeterRules.filledSegmentCount(for: 1), 26)
        XCTAssertEqual(VUProgressMeterRules.filledSegmentIndices(for: 0.68), Set(0..<17))
    }

    func testSegmentZonesProgressFromGreenThroughAmberToRed() {
        XCTAssertEqual(VUProgressMeterRules.zone(for: 0), .green)
        XCTAssertEqual(VUProgressMeterRules.zone(for: 15), .green)
        XCTAssertEqual(VUProgressMeterRules.zone(for: 16), .amber)
        XCTAssertEqual(VUProgressMeterRules.zone(for: 21), .amber)
        XCTAssertEqual(VUProgressMeterRules.zone(for: 22), .red)
        XCTAssertEqual(VUProgressMeterRules.zone(for: 25), .red)
    }

    func testIndeterminateWindowWrapsAndRemainsInRange() {
        XCTAssertEqual(VUProgressMeterRules.activeSegmentIndices(for: -1), [0, 1, 25])

        for phase in -48...48 {
            let segments = VUProgressMeterRules.activeSegmentIndices(for: phase)

            XCTAssertEqual(segments.count, 3)
            XCTAssertTrue(segments.allSatisfy { (0..<VUProgressMeterRules.segmentCount).contains($0) })
            XCTAssertEqual(segments, VUProgressMeterRules.activeSegmentIndices(for: phase + 26))
        }
    }

    func testReducedMotionWindowIsStableAndCentered() {
        XCTAssertEqual(VUProgressMeterRules.reducedMotionSegments, [11, 12, 13])
    }
}
