import Combine
import Foundation

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case manualFailure(String)
}

@MainActor
final class UpdateStore: ObservableObject {
    private static let dismissedVersionKey = "TrackDownloaderDismissedUpdateVersion"

    @Published private(set) var status: UpdateStatus = .idle

    private let checker: any UpdateChecking
    private let installedVersionProvider: () -> String?
    private let installedBuildProvider: () -> String?
    private let defaults: UserDefaults
    private var automaticCheckHasStarted = false
    private var activeRequestID: UUID?
    private var activeTask: Task<Void, Never>?

    var installedVersionText: String {
        guard let installedVersion = installedVersionProvider() else {
            return "Version unavailable"
        }
        guard let installedBuild = installedBuildProvider() else {
            return "Version \(installedVersion)"
        }
        return "Version \(installedVersion) (Build \(installedBuild))"
    }

    init(
        checker: any UpdateChecking,
        installedVersionProvider: @escaping () -> String?,
        installedBuildProvider: @escaping () -> String? = { nil },
        defaults: UserDefaults = .standard
    ) {
        self.checker = checker
        self.installedVersionProvider = installedVersionProvider
        self.installedBuildProvider = installedBuildProvider
        self.defaults = defaults
    }

    static func live(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> UpdateStore {
        UpdateStore(
            checker: GitHubReleaseUpdateChecker(),
            installedVersionProvider: {
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            },
            installedBuildProvider: {
                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            },
            defaults: defaults
        )
    }

    #if DEBUG
    static func fixture(status: UpdateStatus) -> UpdateStore {
        let store = UpdateStore(
            checker: FixtureUpdateChecker(),
            installedVersionProvider: { "1.1.0" },
            installedBuildProvider: { "20261002.4" }
        )
        store.automaticCheckHasStarted = true
        store.status = status
        return store
    }
    #endif

    func beginAutomaticCheck() {
        guard !automaticCheckHasStarted else { return }
        automaticCheckHasStarted = true
        startCheck(kind: .automatic)
    }

    func beginManualCheck() {
        startCheck(kind: .manual)
    }

    func dismissAvailableUpdate() {
        guard case .available(let release) = status else { return }
        defaults.set(release.version.description, forKey: Self.dismissedVersionKey)
        status = .idle
    }

    private func startCheck(kind: CheckKind) {
        activeTask?.cancel()

        let requestID = UUID()
        activeRequestID = requestID
        status = .checking
        let checker = self.checker

        activeTask = Task { [weak self, checker] in
            do {
                guard let installedVersion = self?.installedVersionProvider() else {
                    throw UpdateCheckError.invalidInstalledVersion
                }
                let result = try await checker.check(installedVersion: installedVersion)
                guard !Task.isCancelled else { return }
                self?.finish(result, kind: kind, for: requestID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(error, kind: kind, for: requestID)
            }
        }
    }

    private func finish(_ result: UpdateCheckResult, kind: CheckKind, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeTask = nil
        activeRequestID = nil

        switch result {
        case .upToDate:
            status = .upToDate
        case .updateAvailable(let release):
            if kind == .automatic,
               defaults.string(forKey: Self.dismissedVersionKey) == release.version.description {
                status = .idle
            } else {
                status = .available(release)
            }
        }
    }

    private func finish(_ error: Error, kind: CheckKind, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeTask = nil
        activeRequestID = nil
        status = kind == .automatic ? .idle : .manualFailure(message(for: error))
    }

    private func message(for error: Error) -> String {
        switch error as? UpdateCheckError {
        case .noPublicRelease:
            return "No public release is available yet. Try again later."
        case .rateLimited:
            return "GitHub is temporarily limiting update checks. Try again later."
        case .networkUnavailable:
            return "Couldn't check for updates. Check your connection and try again."
        case .invalidInstalledVersion:
            return "This build has no valid version number."
        case .invalidResponse, .none:
            return "Couldn't read the latest release information. Try again later."
        }
    }
}

private enum CheckKind {
    case automatic
    case manual
}

#if DEBUG
private struct FixtureUpdateChecker: UpdateChecking {
    func check(installedVersion: String) async throws -> UpdateCheckResult {
        throw UpdateCheckError.networkUnavailable
    }
}
#endif
