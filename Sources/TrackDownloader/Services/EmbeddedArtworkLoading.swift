import AVFoundation
import Foundation
import ImageIO

protocol EmbeddedArtworkLoading: Sendable {
    func loadArtwork(from fileURL: URL) async -> Data?
}

struct EmbeddedArtworkLoader: EmbeddedArtworkLoading {
    func loadArtwork(from fileURL: URL) async -> Data? {
        guard fileURL.isFileURL else { return nil }

        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.commonMetadata),
              let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
              let artworkData = try? await artworkItem.load(.dataValue),
              isReadableImageData(artworkData) else {
            return nil
        }

        return artworkData
    }

    private func isReadableImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
