import Foundation

enum ToolResolutionError: Error, Equatable {
    case missingTool(String)
}

enum ToolResolver {
    static func resolve(_ name: String) throws -> URL {
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
        }

        if let match = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: match)
        }

        throw ToolResolutionError.missingTool(name)
    }
}
