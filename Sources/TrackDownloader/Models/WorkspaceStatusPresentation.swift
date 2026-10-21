import Foundation

struct WorkspaceStatusPresentation: Equatable {
    let stateText: String
    let stateSystemImage: String
    let stateRole: SemanticStatusRole
    let outputPath: String
    let libraryText: String
    let accessibilityLabel: String

    init(sourceStatus: SourcePaneStatusPresentation, outputDirectory: URL, libraryCount: Int) {
        stateText = sourceStatus.text
        stateSystemImage = sourceStatus.systemImage
        stateRole = sourceStatus.role
        outputPath = outputDirectory.path
        libraryText = libraryCount == 1 ? "1 track" : "\(libraryCount) tracks"
        accessibilityLabel = "\(sourceStatus.text). Output \(outputDirectory.path). Library \(libraryText)."
    }
}
