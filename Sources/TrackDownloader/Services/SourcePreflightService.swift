import Foundation
import TrackDownloaderCore

protocol SourcePreflightServicing: Sendable {
    func inspect(sourceURL: URL) async throws -> SourcePreflightResult
    func cancel()
}

enum SourcePreflightServiceError: Error, Equatable, Sendable {
    case missingDependency(name: String)
    case privateSource
    case signInUnreadable
    case unavailable
    case transient
    case invalidResponse
    case oversizedResponse

    var message: String {
        switch self {
        case .missingDependency:
            "Source checking needs yt-dlp and Deno. Open Settings > Engine Health."
        case .privateSource:
            "This source is private or requires access."
        case .signInUnreadable:
            "Track Downloader couldn't read your SoundCloud login from the browser. Check Settings > SoundCloud Sign-In."
        case .unavailable:
            "This source is unavailable."
        case .transient:
            "The source could not be checked right now."
        case .invalidResponse, .oversizedResponse:
            "Track Downloader could not read this source."
        }
    }
}

struct SourcePreflightService: SourcePreflightServicing {
    private let processRunner: any ProcessRunning
    private let toolResolver: @Sendable (String) throws -> URL
    private let signIn: @Sendable () -> SoundCloudSignIn

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        toolResolver: @escaping @Sendable (String) throws -> URL = { try ToolResolver.resolve($0) },
        signIn: @escaping @Sendable () -> SoundCloudSignIn = { SoundCloudSignInPreference.load() }
    ) {
        self.processRunner = processRunner
        self.toolResolver = toolResolver
        self.signIn = signIn
    }

    func inspect(sourceURL: URL) async throws -> SourcePreflightResult {
        let ytDLP = try resolveTool(named: "yt-dlp")
        let deno = try resolveTool(named: "deno")

        let cookiesBrowser = signIn().cookiesBrowser(for: sourceURL)
        let process: CommandResult
        do {
            process = try await processRunner.run(
                executable: ytDLP,
                arguments: SourcePreflightCommandBuilder.arguments(
                    sourceURL: sourceURL,
                    cookiesBrowser: cookiesBrowser,
                    denoPath: deno.path
                ),
                onLine: { _ in }
            )
        } catch {
            throw SourcePreflightServiceError.transient
        }

        guard process.exitCode == 0 else {
            throw classifiedFailure(from: process.output, usedSignIn: cookiesBrowser != nil)
        }

        let data = Data(process.output.utf8)
        guard data.count <= SourcePreflightParser.maximumJSONBytes else {
            throw SourcePreflightServiceError.oversizedResponse
        }

        do {
            return try SourcePreflightParser.parse(data)
        } catch SourcePreflightParsingError.oversized {
            throw SourcePreflightServiceError.oversizedResponse
        } catch {
            throw SourcePreflightServiceError.invalidResponse
        }
    }

    func cancel() {
        processRunner.cancel()
    }

    private func resolveTool(named name: String) throws -> URL {
        do {
            return try toolResolver(name)
        } catch {
            throw SourcePreflightServiceError.missingDependency(name: name)
        }
    }

    private func classifiedFailure(from output: String, usedSignIn: Bool) -> SourcePreflightServiceError {
        let normalized = output
            .replacingOccurrences(
                of: "https?://\\S+",
                with: "",
                options: .regularExpression
            )
            .lowercased()
        if usedSignIn,
           normalized.contains("cookie"),
           ["could not", "failed", "not permitted", "permission denied", "unable to"]
            .contains(where: normalized.contains) {
            return .signInUnreadable
        }
        if normalized.contains("private")
            || normalized.contains("sign in")
            || normalized.contains("login")
            || normalized.contains("requires access") {
            return .privateSource
        }
        if normalized.contains("unavailable")
            || normalized.contains("removed")
            || normalized.contains("deleted")
            || normalized.contains("not available") {
            return .unavailable
        }
        return .transient
    }
}
