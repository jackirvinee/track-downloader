import Foundation

protocol LibraryOrganizationPersisting {
    func load() throws -> LibraryOrganization
    func save(_ organization: LibraryOrganization) throws
}

struct FileLibraryOrganizationPersistence: LibraryOrganizationPersisting {
    let fileURL: URL

    static func applicationSupport(fileManager: FileManager = .default) -> Self {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return Self(
            fileURL: base
                .appendingPathComponent("Track Downloader", isDirectory: true)
                .appendingPathComponent("Library Organization.json")
        )
    }

    func load() throws -> LibraryOrganization {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LibraryOrganization()
        }
        return try JSONDecoder().decode(LibraryOrganization.self, from: Data(contentsOf: fileURL))
    }

    func save(_ organization: LibraryOrganization) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(organization).write(to: fileURL, options: .atomic)
    }
}

final class MemoryLibraryOrganizationPersistence: LibraryOrganizationPersisting {
    var organization: LibraryOrganization
    var saveError: Error?

    init(organization: LibraryOrganization = LibraryOrganization()) {
        self.organization = organization
    }

    func load() throws -> LibraryOrganization {
        organization
    }

    func save(_ organization: LibraryOrganization) throws {
        if let saveError { throw saveError }
        self.organization = organization
    }
}
