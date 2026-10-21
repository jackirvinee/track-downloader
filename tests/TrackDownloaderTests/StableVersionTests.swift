import XCTest
@testable import TrackDownloader

final class StableVersionTests: XCTestCase {
    func testBundleStringAcceptsTwoComponentsWithZeroPatch() {
        let version = StableVersion(bundleValue: "1.0")

        XCTAssertEqual(version?.major, 1)
        XCTAssertEqual(version?.minor, 0)
        XCTAssertEqual(version?.patch, 0)
        XCTAssertEqual(version?.description, "1.0.0")
    }

    func testBundleStringAcceptsThreeComponents() {
        let version = StableVersion(bundleValue: "1.2.3")

        XCTAssertEqual(version?.major, 1)
        XCTAssertEqual(version?.minor, 2)
        XCTAssertEqual(version?.patch, 3)
    }

    func testReleaseTagAcceptsOptionalLowercaseV() {
        XCTAssertNotNil(StableVersion(releaseTag: "1.2.3"))
        XCTAssertNotNil(StableVersion(releaseTag: "v1.2.3"))
    }

    func testDescriptionIsCanonical() {
        XCTAssertEqual(StableVersion(releaseTag: "v1.2.3")?.description, "1.2.3")
    }

    func testRejectsEmptyAndWhitespace() {
        for input in ["", " ", "\t", "\n", " 1.2.3", "1.2.3 "] {
            XCTAssertNil(StableVersion(bundleValue: input), input)
            XCTAssertNil(StableVersion(releaseTag: input), input)
        }
    }

    func testRejectsMalformedBundleComponentCounts() {
        XCTAssertNil(StableVersion(bundleValue: "1"))
        XCTAssertNil(StableVersion(bundleValue: "1.2.3.4"))
    }

    func testRejectsMalformedReleaseTags() {
        for input in ["v1.2", "vv1.2.3", "V1.2.3"] {
            XCTAssertNil(StableVersion(releaseTag: input), input)
        }
    }

    func testRejectsLeadingZeros() {
        for input in ["01.2.3", "1.02.3", "1.2.03"] {
            XCTAssertNil(StableVersion(bundleValue: input), input)
            XCTAssertNil(StableVersion(releaseTag: input), input)
            XCTAssertNil(StableVersion(releaseTag: "v\(input)"), input)
        }
    }

    func testRejectsNegativeValues() {
        for input in ["-1.2.3", "1.-2.3", "1.2.-3"] {
            XCTAssertNil(StableVersion(bundleValue: input), input)
            XCTAssertNil(StableVersion(releaseTag: input), input)
            XCTAssertNil(StableVersion(releaseTag: "v\(input)"), input)
        }
    }

    func testRejectsIntegerOverflow() {
        let input = "999999999999999999999999999.2.3"

        XCTAssertNil(StableVersion(bundleValue: input))
        XCTAssertNil(StableVersion(releaseTag: input))
        XCTAssertNil(StableVersion(releaseTag: "v\(input)"))
    }

    func testRejectsMetadata() {
        for input in ["1.2.3+build", "v1.2.3+build"] {
            XCTAssertNil(StableVersion(bundleValue: input), input)
            XCTAssertNil(StableVersion(releaseTag: input), input)
        }
    }

    func testRejectsAllPrereleases() {
        for input in ["1.2.3-beta", "v2.0.0-rc.1"] {
            XCTAssertNil(StableVersion(bundleValue: input), input)
            XCTAssertNil(StableVersion(releaseTag: input), input)
        }
    }

    func testEqualNormalizedVersionsCompareEqual() {
        XCTAssertEqual(
            StableVersion(bundleValue: "1.0"),
            StableVersion(releaseTag: "v1.0.0")
        )
        XCTAssertEqual(
            StableVersion(bundleValue: "1.2.3"),
            StableVersion(releaseTag: "1.2.3")
        )
    }

    func testVersionsOrderByMajorMinorThenPatch() {
        XCTAssertLessThan(
            StableVersion(releaseTag: "1.9.9")!,
            StableVersion(releaseTag: "2.0.0")!
        )
        XCTAssertLessThan(
            StableVersion(releaseTag: "1.2.9")!,
            StableVersion(releaseTag: "1.3.0")!
        )
    }

    func testStableVersionIsHashable() {
        let versions: Set<StableVersion> = [
            StableVersion(bundleValue: "1.0")!,
            StableVersion(releaseTag: "v1.0.0")!
        ]

        XCTAssertEqual(versions.count, 1)
    }
}
