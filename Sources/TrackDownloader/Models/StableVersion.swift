struct StableVersion: Equatable, Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    init?(bundleValue: String) {
        let components = bundleValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        guard let major = Self.parseComponent(components[0]),
              let minor = Self.parseComponent(components[1]) else { return nil }

        let patch = components.count == 3 ? Self.parseComponent(components[2]) : 0
        guard let patch else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    init?(releaseTag: String) {
        let version = releaseTag.first == "v" ? String(releaseTag.dropFirst()) : releaseTag
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Self.parseComponent(components[0]),
              let minor = Self.parseComponent(components[1]),
              let patch = Self.parseComponent(components[2]) else { return nil }

        self.init(major: major, minor: minor, patch: patch)
    }

    private init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: StableVersion, rhs: StableVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parseComponent(_ component: Substring) -> Int? {
        guard !component.isEmpty else { return nil }
        guard component.count == 1 || component.first != "0" else { return nil }
        guard component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(component)
    }
}
