// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackDownloader",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TrackDownloaderCore", targets: ["TrackDownloaderCore"]),
        .library(name: "TrackDownloaderChromeCompanion", targets: ["TrackDownloaderChromeCompanion"]),
        .executable(name: "TrackDownloader", targets: ["TrackDownloader"]),
        .executable(name: "TrackDownloaderChromeHost", targets: ["TrackDownloaderChromeHost"])
    ],
    targets: [
        .target(name: "TrackDownloaderCore"),
        .target(
            name: "TrackDownloaderChromeCompanion",
            dependencies: ["TrackDownloaderCore"]
        ),
        .executableTarget(
            name: "TrackDownloaderChromeHost",
            dependencies: ["TrackDownloaderChromeCompanion"]
        ),
        .executableTarget(
            name: "TrackDownloader",
            dependencies: ["TrackDownloaderCore", "TrackDownloaderChromeCompanion"]
        ),
        .testTarget(
            name: "TrackDownloaderCoreTests",
            dependencies: ["TrackDownloaderCore"]
        ),
        .testTarget(
            name: "TrackDownloaderChromeCompanionTests",
            dependencies: ["TrackDownloaderChromeCompanion", "TrackDownloaderCore"]
        ),
        .testTarget(
            name: "TrackDownloaderTests",
            dependencies: ["TrackDownloader", "TrackDownloaderCore", "TrackDownloaderChromeCompanion"]
        )
    ]
)
