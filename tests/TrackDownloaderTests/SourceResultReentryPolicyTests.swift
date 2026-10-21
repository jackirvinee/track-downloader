import TrackDownloaderCore
import XCTest
@testable import TrackDownloader

final class SourceResultReentryPolicyTests: XCTestCase {
    func testOnlySavedResultSchedulesTheOnePointTwoSecondReturn() {
        XCTAssertEqual(SourceResultReentryPolicy.delayNanoseconds, 1_200_000_000)
        XCTAssertTrue(SourceResultReentryPolicy.shouldSchedule(for: sampleResultState))
        XCTAssertFalse(SourceResultReentryPolicy.shouldSchedule(for: .idle))
        XCTAssertFalse(SourceResultReentryPolicy.shouldSchedule(for: .cancelled))
        XCTAssertFalse(SourceResultReentryPolicy.shouldSchedule(for: .failed(sampleFailure)))
    }

    private var sampleResultState: DownloadState {
        .finished(sampleResult())
    }

    private var sampleFailure: DownloadFailurePresentation {
        DownloadFailurePresentation(
            kind: .unexpected,
            title: "Download failed",
            message: "The download did not finish.",
            technicalDetails: nil
        )
    }

    private func sampleResult() -> DownloadResult {
        let fileURL = URL(fileURLWithPath: "/tmp/reentry-policy-test.m4a")
        return DownloadResult(
            fileURL: fileURL,
            metadata: TrackMetadata(title: "Re-entry test"),
            quality: AudioQuality(
                fileURL: fileURL,
                codec: "aac",
                kbps: 256,
                sampleRateHz: 44_100,
                verdict: .good
            )
        )
    }
}
