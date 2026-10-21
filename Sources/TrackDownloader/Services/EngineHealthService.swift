import Foundation

protocol EngineHealthChecking: Sendable {
    func check() async -> EngineHealthSnapshot
}

struct EngineHealthService: EngineHealthChecking, Sendable {
    static let maximumVersionOutputBytes = 16_384

    private let processRunner: any ProcessRunning
    private let toolResolver: @Sendable (String) throws -> URL

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        toolResolver: @escaping @Sendable (String) throws -> URL = { try ToolResolver.resolve($0) }
    ) {
        self.processRunner = processRunner
        self.toolResolver = toolResolver
    }

    func check() async -> EngineHealthSnapshot {
        var tools: [EngineToolHealth] = []
        tools.reserveCapacity(EngineToolID.allCases.count)
        for tool in EngineToolID.allCases {
            tools.append(await health(for: tool))
        }
        return EngineHealthSnapshot(tools: tools, ejsEnabled: true)
    }

    private func health(for tool: EngineToolID) async -> EngineToolHealth {
        let executable: URL
        do {
            executable = try toolResolver(tool.executableName)
        } catch {
            return EngineToolHealth(
                id: tool,
                status: .unavailable,
                recoveryCommand: tool.missingRecoveryCommand
            )
        }

        do {
            let result = try await processRunner.run(
                executable: executable,
                arguments: tool.versionArguments,
                onLine: { _ in }
            )
            guard result.exitCode == 0,
                  let version = Self.parseVersion(tool: tool, output: result.output)
            else {
                return unrecognizedHealth(for: tool)
            }
            return EngineToolHealth(id: tool, status: .available(version: version), recoveryCommand: nil)
        } catch {
            return unrecognizedHealth(for: tool)
        }
    }

    private func unrecognizedHealth(for tool: EngineToolID) -> EngineToolHealth {
        EngineToolHealth(
            id: tool,
            status: .versionUnrecognized,
            recoveryCommand: tool.unrecognizedVersionRecoveryCommand
        )
    }

    private static func parseVersion(tool: EngineToolID, output: String) -> String? {
        guard output.lengthOfBytes(using: .utf8) <= maximumVersionOutputBytes else { return nil }

        switch tool {
        case .ytDLP:
            return captureVersion(in: output, pattern: "^\\s*([0-9]+(?:\\.[0-9]+)+)\\s*$")
        case .ffmpeg:
            return captureVersion(in: output, pattern: "(?:^|\\n)ffmpeg version ([0-9]+(?:\\.[0-9]+)+)(?:\\s|$)")
        case .ffprobe:
            return captureVersion(in: output, pattern: "(?:^|\\n)ffprobe version ([0-9]+(?:\\.[0-9]+)+)(?:\\s|$)")
        case .deno:
            return captureVersion(in: output, pattern: "(?:^|\\n)deno ([0-9]+(?:\\.[0-9]+)+)(?:\\s|$)")
        }
    }

    private static func captureVersion(in output: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output)
        else { return nil }
        return String(output[range])
    }
}
