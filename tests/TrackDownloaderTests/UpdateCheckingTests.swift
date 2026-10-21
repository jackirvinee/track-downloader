import Foundation
import XCTest
@testable import TrackDownloader

actor RecordingUpdateTransport: UpdateHTTPTransport {
    private(set) var requests: [URLRequest] = []
    let result: Result<UpdateHTTPResponse, Error>

    init(result: Result<UpdateHTTPResponse, Error>) {
        self.result = result
    }

    func send(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        requests.append(request)
        return try result.get()
    }
}

actor CountingChunkSource {
    private let chunks: [Data]
    private var index = 0
    private var requestCount = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func next() -> Data? {
        requestCount += 1
        guard index < chunks.count else {
            return nil
        }
        defer { index += 1 }
        return chunks[index]
    }

    func count() -> Int {
        requestCount
    }
}

final class UpdateCheckingTests: XCTestCase {
    private let endpoint = URL(string: "https://example.invalid/releases/latest")!
    private let validPageURL = URL(string: "https://github.com/jackirvinee/track-downloader/releases/tag/v1.1.0")!

    func testRequestUsesInjectedEndpointAndSafeHeaders() async throws {
        let transport = RecordingUpdateTransport(result: .success(response(payload: validPayload())))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        _ = try await checker.check(installedVersion: "1.0")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, endpoint)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNotNil(requests.first?.timeoutInterval)
        XCTAssertGreaterThan(requests.first?.timeoutInterval ?? 0, 0)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Api-Key"))
    }

    func testValidStableReleaseProducesUpdateAndPreservesExactPageURL() async throws {
        let transport = RecordingUpdateTransport(result: .success(response(payload: validPayload())))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        let result = try await checker.check(installedVersion: "1.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                UpdateRelease(
                    version: StableVersion(releaseTag: "v1.1.0")!,
                    notes: "Safer downloads and clearer errors.",
                    pageURL: validPageURL
                )
            )
        )
    }

    func testEqualReleaseIsUpToDate() async throws {
        let transport = RecordingUpdateTransport(result: .success(response(payload: validPayload(tag: "v1.0.0"))))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        let result = try await checker.check(installedVersion: "1.0")
        XCTAssertEqual(result, .upToDate)
    }

    func testOlderReleaseIsUpToDate() async throws {
        let transport = RecordingUpdateTransport(result: .success(response(payload: validPayload(tag: "v0.9.0"))))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        let result = try await checker.check(installedVersion: "1.0")
        XCTAssertEqual(result, .upToDate)
    }

    func testEmptyBodyUsesFallbackNotes() async throws {
        let payload = validPayload(body: "")
        let transport = RecordingUpdateTransport(result: .success(response(payload: payload)))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        let result = try await checker.check(installedVersion: "1.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                UpdateRelease(
                    version: StableVersion(releaseTag: "v1.1.0")!,
                    notes: "See the GitHub release page for details.",
                    pageURL: validPageURL
                )
            )
        )
    }

    func testMissingBodyUsesFallbackNotes() async throws {
        let transport = RecordingUpdateTransport(result: .success(response(payload: validPayload(body: nil))))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        let result = try await checker.check(installedVersion: "1.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                UpdateRelease(
                    version: StableVersion(releaseTag: "v1.1.0")!,
                    notes: "See the GitHub release page for details.",
                    pageURL: validPageURL
                )
            )
        )
    }

    func testNonEmptyBodyIsTrimmedWithoutMarkdownInterpretation() async throws {
        let payload = validPayload(body: "\n  **Keep this Markdown**  \n")
        let transport = RecordingUpdateTransport(result: .success(response(payload: payload)))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        let result = try await checker.check(installedVersion: "1.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                UpdateRelease(
                    version: StableVersion(releaseTag: "v1.1.0")!,
                    notes: "**Keep this Markdown**",
                    pageURL: validPageURL
                )
            )
        )
    }

    func testNotFoundMeansNoPublicRelease() async {
        await assertError(.noPublicRelease, for: response(statusCode: 404))
    }

    func testForbiddenAndTooManyRequestsMeanRateLimited() async {
        await assertError(.rateLimited, for: response(statusCode: 403))
        await assertError(.rateLimited, for: response(statusCode: 429))
    }

    func testOtherNonSuccessStatusMeansInvalidResponse() async {
        await assertError(.invalidResponse, for: response(statusCode: 500))
    }

    func testNetworkFailuresMeanNetworkUnavailable() async {
        for code in [
            URLError.Code.timedOut,
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .secureConnectionFailed,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .cannotLoadFromNetwork,
            .dataNotAllowed,
            .internationalRoamingOff
        ] {
            let transport = RecordingUpdateTransport(result: .failure(URLError(code)))
            let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

            do {
                _ = try await checker.check(installedVersion: "1.0")
                XCTFail("Expected networkUnavailable for \(code)")
            } catch let error as UpdateCheckError {
                XCTAssertEqual(error, .networkUnavailable)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnrelatedURLErrorRemainsInvalidResponse() async {
        let transport = RecordingUpdateTransport(result: .failure(URLError(.badURL)))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        do {
            _ = try await checker.check(installedVersion: "1.0")
            XCTFail("Expected invalidResponse")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDraftAndPrereleaseMeanNoPublicRelease() async {
        await assertError(.noPublicRelease, for: response(payload: validPayload(draft: true)))
        await assertError(.noPublicRelease, for: response(payload: validPayload(prerelease: true)))
    }

    func testMalformedJSONMeansInvalidResponse() async {
        await assertError(.invalidResponse, for: UpdateHTTPResponse(data: Data("not json".utf8), statusCode: 200))
    }

    func testMissingRequiredFieldMeansInvalidResponse() async {
        for key in ["tag_name", "html_url", "draft", "prerelease"] {
            var payload = validPayload()
            payload.removeValue(forKey: key)
            await assertError(.invalidResponse, for: response(payload: payload))
        }
    }

    func testOversizedResponseIsRejectedBeforeReadingFollowingChunk() async {
        let source = CountingChunkSource(chunks: [
            Data(repeating: 0x78, count: 1_048_576),
            Data(repeating: 0x78, count: 1),
            Data("this chunk must not be read".utf8)
        ])
        let body = UpdateHTTPResponseBody(nextChunk: { await source.next() })
        let response = UpdateHTTPResponse(body: body, statusCode: 200)
        let transport = RecordingUpdateTransport(result: .success(response))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        do {
            _ = try await checker.check(installedVersion: "1.0")
            XCTFail("Expected invalidResponse")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await source.count()
        XCTAssertEqual(requestCount, 2)
    }

    func testInvalidInstalledVersionMeansInvalidInstalledVersion() async throws {
        let transport = RecordingUpdateTransport(result: .success(response(payload: validPayload())))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        do {
            _ = try await checker.check(installedVersion: "1")
            XCTFail("Expected invalidInstalledVersion")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .invalidInstalledVersion)
        }
    }

    func testMalformedReleaseTagMeansInvalidResponse() async {
        await assertError(.invalidResponse, for: response(payload: validPayload(tag: "v1.1")))
    }

    func testHostileOrInconsistentPageURLsMeanInvalidResponse() async {
        let urls = [
            "http://github.com/jackirvinee/track-downloader/releases/tag/v1.1.0",
            "https://user:password@github.com/jackirvinee/track-downloader/releases/tag/v1.1.0",
            "https://evil.example/jackirvinee/track-downloader/releases/tag/v1.1.0",
            "https://github.com/other-owner/track-downloader/releases/tag/v1.1.0",
            "https://github.com/jackirvinee/other-repository/releases/tag/v1.1.0",
            "https://github.com/jackirvinee/track-downloader/releases/latest",
            "https://github.com/jackirvinee/track-downloader/releases/tag/v9.9.9"
        ]

        for url in urls {
            await assertError(.invalidResponse, for: response(payload: validPayload(htmlURL: url)))
        }
    }

    private func assertError(
        _ expected: UpdateCheckError,
        for response: UpdateHTTPResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let transport = RecordingUpdateTransport(result: .success(response))
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint, transport: transport)

        do {
            _ = try await checker.check(installedVersion: "1.0")
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func validPayload(
        tag: String = "v1.1.0",
        htmlURL: String? = nil,
        body: String? = "Safer downloads and clearer errors.",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> [String: Any] {
        [
            "tag_name": tag,
            "html_url": htmlURL ?? "https://github.com/jackirvinee/track-downloader/releases/tag/\(tag)",
            "name": "Track Downloader 1.1.0",
            "body": body ?? NSNull(),
            "draft": draft,
            "prerelease": prerelease
        ]
    }

    private func response(
        statusCode: Int = 200,
        payload: [String: Any]
    ) -> UpdateHTTPResponse {
        UpdateHTTPResponse(
            data: try! JSONSerialization.data(withJSONObject: payload),
            statusCode: statusCode
        )
    }

    private func response(statusCode: Int) -> UpdateHTTPResponse {
        UpdateHTTPResponse(data: Data(), statusCode: statusCode)
    }
}
