/// Which source stream yt-dlp downloads.
///
/// - An uploader's original file (SoundCloud format id `download`) always wins. It has
///   no reported codec or bitrate, so no sort order alone can rank it first.
/// - `quality` is the extractor's own tier: SoundCloud ranks Go+ 256k > 160k AAC >
///   everything else, and YouTube ranks its high > medium > low tiers and puts
///   dynamic-range-compressed (DRC) copies just below their uncompressed twins.
/// - Within a tier, bitrate beats codec, so a 128 kbps MP3 wins over a 96 kbps AAC.
public enum YTDLPAudioSelectionPolicy {
    public static let arguments = [
        "--format", "download/bestaudio/best",
        "--format-sort", "quality,abr,acodec,asr"
    ]
}
