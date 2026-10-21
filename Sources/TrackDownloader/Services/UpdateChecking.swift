import Foundation

struct UpdateHTTPResponse: Sendable {
    let body: UpdateHTTPResponseBody
    let statusCode: Int

    init(data: Data, statusCode: Int) {
        let source = DataUpdateBodySource(data: data)
        self.init(
            body: UpdateHTTPResponseBody(nextChunk: { await source.next() }),
            statusCode: statusCode
        )
    }

    init(body: UpdateHTTPResponseBody, statusCode: Int) {
        self.body = body
        self.statusCode = statusCode
    }

    func collectData(maxBytes: Int) async throws -> Data {
        var data = Data()
        var iterator = body.makeAsyncIterator()

        while let chunk = try await iterator.next() {
            guard chunk.count <= maxBytes - data.count else {
                throw UpdateCheckError.invalidResponse
            }
            data.append(chunk)
        }

        return data
    }
}

struct UpdateHTTPResponseBody: AsyncSequence, Sendable {
    typealias Element = Data

    struct AsyncIterator: AsyncIteratorProtocol {
        private let nextChunk: @Sendable () async throws -> Data?

        init(nextChunk: @escaping @Sendable () async throws -> Data?) {
            self.nextChunk = nextChunk
        }

        mutating func next() async throws -> Data? {
            try await nextChunk()
        }
    }

    private let makeIteratorClosure: @Sendable () -> AsyncIterator

    init(nextChunk: @escaping @Sendable () async throws -> Data?) {
        makeIteratorClosure = {
            AsyncIterator(nextChunk: nextChunk)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        makeIteratorClosure()
    }
}

protocol UpdateHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> UpdateHTTPResponse
}

struct URLSessionUpdateTransport: UpdateHTTPTransport, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        let source = URLSessionUpdateBodySource(bytes: bytes)
        return UpdateHTTPResponse(
            body: UpdateHTTPResponseBody(nextChunk: { try await source.nextChunk() }),
            statusCode: httpResponse.statusCode
        )
    }
}

private actor DataUpdateBodySource {
    private var data: Data?

    init(data: Data) {
        self.data = data
    }

    func next() -> Data? {
        defer { data = nil }
        return data
    }
}

private actor URLSessionUpdateBodySource<Bytes: AsyncSequence & Sendable> where Bytes.Element == UInt8 {
    private var iterator: Bytes.AsyncIterator

    init(bytes: Bytes) {
        self.iterator = bytes.makeAsyncIterator()
    }

    func nextChunk() async throws -> Data? {
        var chunk = Data()
        var iterator = self.iterator
        while chunk.count < 8_192 {
            guard let byte = try await iterator.next() else {
                self.iterator = iterator
                break
            }
            chunk.append(byte)
        }
        self.iterator = iterator
        return chunk.isEmpty ? nil : chunk
    }
}

protocol UpdateChecking: Sendable {
    func check(installedVersion: String) async throws -> UpdateCheckResult
}

struct GitHubReleaseUpdateChecker: UpdateChecking, Sendable {
    private static let defaultEndpoint = URL(string: "https://api.github.com/repos/jackirvinee/track-downloader/releases/latest")!

    private let endpoint: URL
    private let transport: any UpdateHTTPTransport

    init(
        endpoint: URL = Self.defaultEndpoint,
        transport: any UpdateHTTPTransport = URLSessionUpdateTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func check(installedVersion: String) async throws -> UpdateCheckResult {
        guard let installedVersion = StableVersion(bundleValue: installedVersion) else {
            throw UpdateCheckError.invalidInstalledVersion
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let response: UpdateHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as UpdateCheckError {
            throw error
        } catch let error as URLError {
            throw Self.updateCheckError(for: error)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        switch response.statusCode {
        case 200:
            break
        case 404:
            throw UpdateCheckError.noPublicRelease
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.invalidResponse
        }

        let data: Data
        do {
            data = try await response.collectData(maxBytes: 1_048_576)
        } catch let error as UpdateCheckError {
            throw error
        } catch let error as URLError {
            throw Self.updateCheckError(for: error)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        let release: GitHubReleaseResponse
        do {
            release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        guard !release.draft, !release.prerelease else {
            throw UpdateCheckError.noPublicRelease
        }
        guard let releaseVersion = StableVersion(releaseTag: release.tagName),
              isValidPageURL(release.htmlURL, tagName: release.tagName) else {
            throw UpdateCheckError.invalidResponse
        }

        guard releaseVersion > installedVersion else {
            return .upToDate
        }

        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .updateAvailable(
            UpdateRelease(
                version: releaseVersion,
                notes: notes?.isEmpty == false ? notes! : "See the GitHub release page for details.",
                pageURL: release.htmlURL
            )
        )
    }

    private func isValidPageURL(_ url: URL, tagName: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }

        return url.path == "/jackirvinee/track-downloader/releases/tag/\(tagName)"
    }

    private static func updateCheckError(for error: URLError) -> UpdateCheckError {
        switch error.code {
        case .timedOut,
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
             .internationalRoamingOff:
            return .networkUnavailable
        default:
            return .invalidResponse
        }
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case body
        case draft
        case prerelease
    }
}
