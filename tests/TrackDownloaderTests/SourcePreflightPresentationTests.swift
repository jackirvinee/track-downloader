import XCTest
@testable import TrackDownloader
@testable import TrackDownloaderCore

final class SourcePreflightPresentationTests: XCTestCase {
    func testReadyResultFormatsConciseSourceFactsWithoutSavedFileClaims() {
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: "Night Drive",
            uploader: "Example Artist",
            durationSeconds: 245,
            selectedAudio: SelectedSourceAudio(codec: "opus", bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        ))

        XCTAssertEqual(presentation.title, "Night Drive")
        XCTAssertEqual(presentation.secondaryText, "Example Artist · 4:05")
        XCTAssertEqual(presentation.audioText, "Opus · Estimated 192 kbps · 48 kHz")
        XCTAssertEqual(presentation.assessment, "Compatible export likely")
        XCTAssertFalse((presentation.audioText ?? "").lowercased().contains("saved"))
    }

    func testMissingOptionalFactsUseNeutralTitleAndOmitSupplementaryRows() {
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: nil,
            uploader: nil,
            durationSeconds: nil,
            selectedAudio: SelectedSourceAudio(codec: nil, bitrateKbps: nil, sampleRateHz: nil),
            assessment: .findBetterSource
        ))

        XCTAssertEqual(presentation.title, "Source available")
        XCTAssertNil(presentation.secondaryText)
        XCTAssertNil(presentation.audioText)
        XCTAssertEqual(presentation.assessment, "Find a better source")
    }

    func testDurationAndSampleRateRemainLocallyFormatted() {
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: "Long Form",
            uploader: nil,
            durationSeconds: 3_723,
            selectedAudio: SelectedSourceAudio(codec: "aac", bitrateKbps: nil, sampleRateHz: 44_100),
            assessment: .readyToDownload
        ))

        XCTAssertEqual(presentation.secondaryText, "1:02:03")
        XCTAssertEqual(presentation.audioText, "Aac · 44.1 kHz")
        XCTAssertEqual(presentation.assessment, "Ready to download")
    }

    func testUnavailableMessageHidesDependencyAndRecoveryDetails() {
        let message = SourcePreflightPresentation.unavailableMessage(
            "Source checking needs yt-dlp and Deno. Open Settings > Engine Health."
        )

        XCTAssertEqual(message, "This source could not be checked right now.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("yt-dlp"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("settings"))
    }

    func testAdversarialSourceStringsAreOmittedOrBounded() {
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: "ERROR: [youtube] https://example.com/private?token=secret",
            uploader: String(repeating: "A", count: 500),
            durationSeconds: nil,
            selectedAudio: SelectedSourceAudio(
                codec: "/opt/homebrew/bin/yt-dlp --dump-json",
                bitrateKbps: 192,
                sampleRateHz: 48_000
            ),
            assessment: .compatibleExportLikely
        ))

        XCTAssertEqual(presentation.title, "Source available")
        XCTAssertEqual(presentation.secondaryText, String(repeating: "A", count: 120))
        XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz")
    }

    func testURLSchemesBareDomainsAndDiagnosticsAreNeverPresentedAsSourceFacts() {
        let unsafeValues = [
            "ftp://example.com/private-audio",
            "file:///tmp/example-audio.wav",
            "ftp:/private/secret",
            "file:/private/secret",
            "data:application/json;base64,eyJ0b2tlbiI6InNlY3JldCJ9",
            "cdn.example.com/private-audio?token=secret",
            "zsh: command not found: yt-dlp",
            "Traceback (most recent call last): extractor failed",
            "fatal: could not read source"
        ]

        for unsafeValue in unsafeValues {
            let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
                title: unsafeValue,
                uploader: unsafeValue,
                durationSeconds: nil,
                selectedAudio: SelectedSourceAudio(codec: unsafeValue, bitrateKbps: 192, sampleRateHz: 48_000),
                assessment: .compatibleExportLikely
            ))

            XCTAssertEqual(presentation.title, "Source available", unsafeValue)
            XCTAssertNil(presentation.secondaryText, unsafeValue)
            XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz", unsafeValue)
        }
    }

    func testControlHeavySourceTextIsOmittedInsteadOfRendered() {
        let controlHeavyValue = "\u{001B}[31mNight Drive\u{0007}"
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: controlHeavyValue,
            uploader: controlHeavyValue,
            durationSeconds: nil,
            selectedAudio: SelectedSourceAudio(codec: controlHeavyValue, bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        ))

        XCTAssertEqual(presentation.title, "Source available")
        XCTAssertNil(presentation.secondaryText)
        XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz")
    }

    func testNormalColonAndToolNamedMetadataRemainVisible() {
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: "Crash: Into You",
            uploader: "Fish, Node & Brew Collective",
            durationSeconds: nil,
            selectedAudio: SelectedSourceAudio(codec: "opus", bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        ))

        XCTAssertEqual(presentation.title, "Crash: Into You")
        XCTAssertEqual(presentation.secondaryText, "Fish, Node & Brew Collective")
        XCTAssertEqual(presentation.audioText, "Opus · Estimated 192 kbps · 48 kHz")
    }

    func testSpecificShellDiagnosticRemainsRejectedWithoutBlockingNormalColonMetadata() {
        let rawDiagnostic = "sh: command not found: private-extractor"
        let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: rawDiagnostic,
            uploader: rawDiagnostic,
            durationSeconds: nil,
            selectedAudio: SelectedSourceAudio(codec: rawDiagnostic, bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        ))

        XCTAssertEqual(presentation.title, "Source available")
        XCTAssertNil(presentation.secondaryText)
        XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz")
    }

    func testURIStyleSchemePayloadsAreRejectedAtAnyPunctuationBoundary() {
        let unsafeValues = [
            "urn:isbn:9780141036144",
            "foo:bar",
            "label [ftp:/private]"
        ]

        for unsafeValue in unsafeValues {
            let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
                title: unsafeValue,
                uploader: unsafeValue,
                durationSeconds: nil,
                selectedAudio: SelectedSourceAudio(codec: unsafeValue, bitrateKbps: 192, sampleRateHz: 48_000),
                assessment: .compatibleExportLikely
            ))

            XCTAssertEqual(presentation.title, "Source available", unsafeValue)
            XCTAssertNil(presentation.secondaryText, unsafeValue)
            XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz", unsafeValue)
        }
    }

    func testToolDiagnosticsAreRejectedWithoutSuppressingOrdinaryToolNamedMetadata() {
        let unsafeValues = [
            "curl: (6) Could not resolve host",
            "node:internal/modules/cjs/loader: failed",
            "sh: command not found: private-extractor"
        ]

        for unsafeValue in unsafeValues {
            let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
                title: unsafeValue,
                uploader: unsafeValue,
                durationSeconds: nil,
                selectedAudio: SelectedSourceAudio(codec: unsafeValue, bitrateKbps: 192, sampleRateHz: 48_000),
                assessment: .compatibleExportLikely
            ))

            XCTAssertEqual(presentation.title, "Source available", unsafeValue)
            XCTAssertNil(presentation.secondaryText, unsafeValue)
            XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz", unsafeValue)
        }

        let normalPresentation = SourcePreflightPresentation(result: SourcePreflightResult(
            title: "Crash: Into You",
            uploader: "Brew, Curl, Node & Sh Collective",
            durationSeconds: nil,
            selectedAudio: SelectedSourceAudio(codec: "opus", bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        ))

        XCTAssertEqual(normalPresentation.title, "Crash: Into You")
        XCTAssertEqual(normalPresentation.secondaryText, "Brew, Curl, Node & Sh Collective")
        XCTAssertEqual(normalPresentation.audioText, "Opus · Estimated 192 kbps · 48 kHz")
    }

    func testSchemeNamedMetadataWithWhitespaceAfterColonRemainsVisible() {
        let normalCases = [
            (value: "Data: Dreams", audioText: "Data: Dreams · Estimated 192 kbps · 48 kHz"),
            (value: "About: Time", audioText: "About: Time · Estimated 192 kbps · 48 kHz"),
            (value: "Mailto: You", audioText: "Mailto: You · Estimated 192 kbps · 48 kHz"),
            (value: "Chrome: Hearts", audioText: "Chrome: Hearts · Estimated 192 kbps · 48 kHz")
        ]

        for normalCase in normalCases {
            let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
                title: normalCase.value,
                uploader: normalCase.value,
                durationSeconds: nil,
                selectedAudio: SelectedSourceAudio(codec: normalCase.value, bitrateKbps: 192, sampleRateHz: 48_000),
                assessment: .compatibleExportLikely
            ))

            XCTAssertEqual(presentation.title, normalCase.value, normalCase.value)
            XCTAssertEqual(presentation.secondaryText, normalCase.value, normalCase.value)
            XCTAssertEqual(presentation.audioText, normalCase.audioText, normalCase.value)
        }
    }

    func testSchemeNamedURIPayloadsRemainRejectedWithoutWhitespaceAfterColon() {
        let unsafeValues = [
            "data:text/plain;base64,UHJpdmF0ZQ==",
            "about:blank",
            "mailto:private@example.com",
            "chrome://settings"
        ]

        for unsafeValue in unsafeValues {
            let presentation = SourcePreflightPresentation(result: SourcePreflightResult(
                title: unsafeValue,
                uploader: unsafeValue,
                durationSeconds: nil,
                selectedAudio: SelectedSourceAudio(codec: unsafeValue, bitrateKbps: 192, sampleRateHz: 48_000),
                assessment: .compatibleExportLikely
            ))

            XCTAssertEqual(presentation.title, "Source available", unsafeValue)
            XCTAssertNil(presentation.secondaryText, unsafeValue)
            XCTAssertEqual(presentation.audioText, "Estimated 192 kbps · 48 kHz", unsafeValue)
        }
    }
}
