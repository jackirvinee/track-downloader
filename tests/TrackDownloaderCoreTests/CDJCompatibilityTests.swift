import XCTest
@testable import TrackDownloaderCore

final class CDJCompatibilityTests: XCTestCase {
    // MARK: Rules

    func testUniversalFormatsHaveNoIssues() {
        let universal: [(CDJAudioProbe, String)] = [
            (probe("mp3", rate: 44_100), "mp3"),
            (probe("mp3", rate: 32_000), "mp3"),
            (probe("aac", profile: "LC", rate: 44_100), "m4a"),
            (probe("aac", profile: "LC", rate: 48_000), "mp4"),
            (probe("pcm_s16le", rate: 44_100), "wav"),
            (probe("pcm_s24le", rate: 48_000), "WAV"),
            (probe("pcm_s24be", rate: 48_000), "aiff"),
            (probe("pcm_s16be", rate: 44_100, channels: 1), "aif")
        ]

        for (probe, ext) in universal {
            XCTAssertEqual(CDJFormatRules.issues(for: probe, fileExtension: ext), [], "\(probe.codec!) in .\(ext)")
        }
    }

    func testFlagsFormatsOnlySomeDecksPlay() {
        XCTAssertEqual(issues("flac", rate: 44_100, ext: "flac"), [CDJIssue(.unsupportedFormat, ".flac")])
        XCTAssertEqual(issues("alac", rate: 44_100, ext: "m4a"), [CDJIssue(.unsupportedFormat, "ALAC")])
        XCTAssertEqual(issues("opus", rate: 48_000, ext: "opus"), [CDJIssue(.unsupportedFormat, ".opus")])
        XCTAssertEqual(issues("opus", rate: 48_000, ext: "webm"), [CDJIssue(.unsupportedFormat, ".webm")])
        XCTAssertEqual(
            CDJFormatRules.issues(for: probe("aac", profile: "HE-AAC", rate: 44_100), fileExtension: "m4a"),
            [CDJIssue(.aacProfile, "HE-AAC")]
        )
    }

    func testFlagsPCMBitDepthAndSampleRate() {
        XCTAssertEqual(issues("pcm_f32le", rate: 44_100, ext: "wav"), [CDJIssue(.bitDepth, "32-bit float")])
        XCTAssertEqual(issues("pcm_s32le", rate: 44_100, ext: "wav"), [CDJIssue(.bitDepth, "32-bit")])
        XCTAssertEqual(issues("pcm_u8", rate: 44_100, ext: "wav"), [CDJIssue(.bitDepth, "8-bit")])
        XCTAssertEqual(issues("pcm_s24le", rate: 88_200, ext: "wav"), [CDJIssue(.sampleRate, "88.2 kHz")])
        XCTAssertEqual(issues("pcm_s24be", rate: 96_000, ext: "aiff"), [CDJIssue(.sampleRate, "96 kHz")])
    }

    func testFlagsCodecInTheWrongContainer() {
        XCTAssertEqual(issues("aac", rate: 44_100, ext: "mp3"), [CDJIssue(.extensionMismatch, "aac in .mp3")])
        XCTAssertEqual(issues("mp3", rate: 44_100, ext: "m4a"), [CDJIssue(.extensionMismatch, "mp3 in .m4a")])
        XCTAssertEqual(issues("mp3", rate: 44_100, ext: "wav"), [CDJIssue(.extensionMismatch, "mp3 in .wav")])
    }

    func testLowRateMP3IsOnlyAWarningAndSurroundIsAnError() {
        let lowRate = issues("mp3", rate: 22_050, ext: "mp3")
        XCTAssertEqual(lowRate, [CDJIssue(.mp3LowRate, "22.05 kHz")])
        XCTAssertEqual(lowRate.first?.severity, .warning)
        XCTAssertEqual(issues("mp3", rate: 8_000, ext: "mp3"), [CDJIssue(.sampleRate, "8 kHz")])
        XCTAssertEqual(
            CDJFormatRules.issues(for: probe("pcm_s16le", rate: 44_100, channels: 6), fileExtension: "wav"),
            [CDJIssue(.unsupportedFormat, "6 channels")]
        )
    }

    func testUnreadableAndVideoOnlyFiles() {
        XCTAssertEqual(CDJFormatRules.issues(for: nil, fileExtension: "mp3"), [CDJIssue(.unreadable)])
        XCTAssertEqual(
            CDJFormatRules.issues(for: CDJAudioProbe(codec: nil), fileExtension: "mp3"),
            [CDJIssue(.unreadable, "no audio stream")]
        )
        XCTAssertEqual(
            CDJFormatRules.issues(for: CDJAudioProbe(codec: nil, hasVideo: true), fileExtension: "m4a"),
            [CDJIssue(.notAudio)]
        )
    }

    func testFAT32FileNames() {
        XCTAssertNil(CDJFormatRules.fileNameIssue("Artist - Track ⧸⧸ Remix ＊ [123].m4a"))
        XCTAssertEqual(CDJFormatRules.fileNameIssue("Artist - What?.mp3"), CDJIssue(.fat32Name))
        XCTAssertEqual(CDJFormatRules.fileNameIssue("A: B.wav")?.severity, .info)
    }

    func testSourceCodecsThatPlayWithoutConversion() {
        XCTAssertTrue(CDJFormatRules.isUniversallyPlayable(sourceCodec: "mp4a.40.2", sampleRateHz: 44_100))
        XCTAssertTrue(CDJFormatRules.isUniversallyPlayable(sourceCodec: "aac", sampleRateHz: nil))
        XCTAssertTrue(CDJFormatRules.isUniversallyPlayable(sourceCodec: "MP3", sampleRateHz: 48_000))
        XCTAssertTrue(CDJFormatRules.isUniversallyPlayable(sourceCodec: "pcm_s24le", sampleRateHz: 48_000))
        XCTAssertFalse(CDJFormatRules.isUniversallyPlayable(sourceCodec: "pcm_s24le", sampleRateHz: 96_000))
        XCTAssertFalse(CDJFormatRules.isUniversallyPlayable(sourceCodec: "mp4a.40.5", sampleRateHz: 44_100))
        for codec in ["flac", "alac", "opus", "vorbis", "pcm_f32le"] {
            XCTAssertFalse(CDJFormatRules.isUniversallyPlayable(sourceCodec: codec, sampleRateHz: 44_100), codec)
        }
    }

    // MARK: Plan

    func testKeepsFilesThatAlreadyPlayEverywhere() {
        XCTAssertEqual(plan(probe("aac", profile: "LC", rate: 44_100), "m4a"), .keep)
        XCTAssertEqual(plan(probe("pcm_s24le", rate: 48_000), "wav"), .keep)
        XCTAssertEqual(plan(probe("mp3", rate: 22_050), "mp3"), .keep)
    }

    func testRemuxesLossyAudioInTheWrongContainer() {
        XCTAssertEqual(plan(probe("aac", profile: "LC", rate: 44_100), "mp3"), .remux(fileExtension: "m4a"))
        XCTAssertEqual(plan(probe("mp3", rate: 44_100), "m4a"), .remux(fileExtension: "mp3"))
        XCTAssertEqual(plan(probe("mp3", rate: 44_100), "wav"), .remux(fileExtension: "mp3"))
    }

    func testConvertsLosslessToWAVKeepingDepthAndMovingToACDJRate() {
        XCTAssertEqual(plan(probe("flac", rate: 96_000, bits: 24), "flac"), wav(24, 48_000))
        XCTAssertEqual(plan(probe("flac", rate: 44_100, bits: 16), "flac"), wav(16, 44_100))
        XCTAssertEqual(plan(probe("flac", rate: 44_100), "flac"), wav(24, 44_100))
        XCTAssertEqual(plan(probe("alac", rate: 48_000, bits: 24), "m4a"), wav(24, 48_000))
        XCTAssertEqual(plan(probe("alac", rate: 44_100, bits: 16), "m4a"), wav(16, 44_100))
        XCTAssertEqual(plan(probe("pcm_f32le", rate: 44_100), "wav"), wav(24, 44_100))
        XCTAssertEqual(plan(probe("pcm_s32le", rate: 48_000), "wav"), wav(24, 48_000))
        XCTAssertEqual(plan(probe("pcm_u8", rate: 44_100), "wav"), wav(16, 44_100))
        XCTAssertEqual(plan(probe("pcm_s24le", rate: 88_200), "wav"), wav(24, 44_100))
        XCTAssertEqual(plan(probe("pcm_s24le", rate: 192_000), "wav"), wav(24, 48_000))
        XCTAssertEqual(plan(probe("pcm_s16le", rate: 44_100, channels: 6), "wav"),
                       .convertToWAV(bitDepth: 16, sampleRateHz: 44_100, downmixToStereo: true))
    }

    func testConvertsLossyFormatsSomeDecksCantDecodeTo16BitWAV() {
        XCTAssertEqual(plan(probe("opus", rate: 48_000), "opus"), wav(16, 48_000))
        XCTAssertEqual(plan(probe("vorbis", rate: 44_100), "ogg"), wav(16, 44_100))
        XCTAssertEqual(plan(probe("aac", profile: "HE-AAC", rate: 44_100), "m4a"), wav(16, 44_100))
        XCTAssertEqual(plan(probe("aac", profile: "HE-AAC", rate: 44_100), "mp3"), wav(16, 44_100))
        XCTAssertEqual(plan(probe("aac", profile: "LC", rate: 96_000), "m4a"), wav(16, 48_000))
    }

    func testCannotFixUnreadableFiles() {
        XCTAssertEqual(CDJSafeAction.plan(for: nil, fileExtension: "mp3"), .cannotFix("Broken or not a real audio file"))
        XCTAssertNil(CDJSafeAction.plan(for: nil, fileExtension: "mp3").targetExtension)
    }

    func testFFmpegArgumentsMapOneAudioStreamAndNeverOverwrite() {
        let flac = probe("flac", rate: 96_000, bits: 24)
        XCTAssertEqual(
            wav(24, 48_000).ffmpegArguments(input: "/dev/fd/0", output: "/music/.tmp.wav", probe: flac),
            ["-nostdin", "-v", "error", "-n", "-i", "/dev/fd/0", "-map", "0:a:0", "-map_metadata", "0",
             "-c:a", "pcm_s24le", "-ar", "48000", "/music/.tmp.wav"]
        )
        let surround = CDJSafeAction.convertToWAV(bitDepth: 16, sampleRateHz: 44_100, downmixToStereo: true)
        XCTAssertEqual(
            Array(surround.ffmpegArguments(input: "in", output: "out.wav", probe: flac).suffix(7)),
            ["-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2", "out.wav"]
        )
        XCTAssertEqual(
            Array(CDJSafeAction.remux(fileExtension: "m4a").ffmpegArguments(input: "in", output: "out.m4a", probe: flac).suffix(5)),
            ["-c:a", "copy", "-movflags", "+faststart", "out.m4a"]
        )
        XCTAssertEqual(
            Array(CDJSafeAction.remux(fileExtension: "mp3").ffmpegArguments(input: "in", output: "out.mp3", probe: flac).suffix(3)),
            ["-c:a", "copy", "out.mp3"]
        )
    }

    func testTakesOpusTagsFromTheAudioStream() {
        let opus = CDJAudioProbe(codec: "opus", sampleRateHz: 48_000, tagsAreOnAudioStream: true)
        let arguments = wav(16, 48_000).ffmpegArguments(input: "in", output: "out.wav", probe: opus)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-map_metadata")! + 1], "0:s:a:0")
    }

    func testSummaries() {
        XCTAssertEqual(wav(24, 44_100).summary, "converted to 24-bit WAV, 44.1 kHz")
        XCTAssertEqual(CDJSafeAction.remux(fileExtension: "m4a").summary, "rewrapped as .m4a (audio untouched)")
        XCTAssertEqual(CDJSafeAction.targetSampleRate(32_000), 44_100)
        XCTAssertEqual(CDJSafeAction.targetSampleRate(176_400), 44_100)
        XCTAssertEqual(CDJSafeAction.targetSampleRate(96_000), 48_000)
    }

    // MARK: Probe parsing

    func testParsesFFprobeJSON() throws {
        let flac = try XCTUnwrap(CDJAudioProbe.parse(ffprobeJSON: Data("""
        {"streams":[
          {"codec_type":"audio","codec_name":"flac","profile":"unknown","sample_rate":"96000",
           "channels":2,"bits_per_raw_sample":"24","disposition":{"attached_pic":0}},
          {"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}
         ],
         "format":{"format_name":"flac","duration":"30.000000","tags":{"title":"Night Drive","ARTIST":"Example"}}}
        """.utf8)))

        XCTAssertEqual(flac, CDJAudioProbe(
            codec: "flac", profile: "unknown", sampleRateHz: 96_000, channels: 2,
            bitsPerRawSample: 24, durationSeconds: 30, hasVideo: false, tagsAreOnAudioStream: false
        ))
    }

    func testParsesStreamTagsVideoAndUnreadableOutput() throws {
        let opus = try XCTUnwrap(CDJAudioProbe.parse(ffprobeJSON: Data("""
        {"streams":[{"codec_type":"audio","codec_name":"opus","sample_rate":"48000","channels":2,
                     "bits_per_raw_sample":"N/A","tags":{"title":"Opus Title"}}],
         "format":{"format_name":"ogg","duration":"30.006500"}}
        """.utf8)))
        XCTAssertTrue(opus.tagsAreOnAudioStream)
        XCTAssertNil(opus.bitsPerRawSample)

        let video = try XCTUnwrap(CDJAudioProbe.parse(ffprobeJSON: Data("""
        {"streams":[{"codec_type":"video","codec_name":"h264"}],"format":{"format_name":"mov"}}
        """.utf8)))
        XCTAssertNil(video.codec)
        XCTAssertTrue(video.hasVideo)

        XCTAssertNil(CDJAudioProbe.parse(ffprobeJSON: Data("{}".utf8)))
        XCTAssertNil(CDJAudioProbe.parse(ffprobeJSON: Data("not json".utf8)))
    }

    // MARK: Verification

    func testAcceptsAConvertedCopyThatPassesAndKeepsItsLength() {
        let source = CDJAudioProbe(codec: "flac", sampleRateHz: 96_000, durationSeconds: 300)
        let converted = CDJAudioProbe(codec: "pcm_s24le", sampleRateHz: 48_000, durationSeconds: 300.05)

        XCTAssertNil(CDJSafeAction.verificationProblem(source: source, converted: converted, fileExtension: "wav"))
    }

    func testRejectsBrokenFailingOrShortenedCopies() {
        let source = CDJAudioProbe(codec: "flac", sampleRateHz: 96_000, durationSeconds: 300)

        XCTAssertEqual(
            CDJSafeAction.verificationProblem(source: source, converted: nil, fileExtension: "wav"),
            "the converted file is unreadable"
        )
        XCTAssertEqual(
            CDJSafeAction.verificationProblem(
                source: source,
                converted: CDJAudioProbe(codec: "pcm_s24le", sampleRateHz: 96_000, durationSeconds: 300),
                fileExtension: "wav"
            ),
            "the converted file still fails: Sample rate not supported (96 kHz)"
        )
        XCTAssertEqual(
            CDJSafeAction.verificationProblem(
                source: source,
                converted: CDJAudioProbe(codec: "pcm_s24le", sampleRateHz: 48_000, durationSeconds: 120),
                fileExtension: "wav"
            ),
            "the length changed (300.00s to 120.00s)"
        )
    }

    func testAllowsOnePercentWhenTheSourceLengthIsAnEstimate() {
        let adts = CDJAudioProbe(codec: "aac", profile: "LC", sampleRateHz: 44_100, durationSeconds: 30.216)
        let remuxed = CDJAudioProbe(codec: "aac", profile: "LC", sampleRateHz: 44_100, durationSeconds: 30.023)

        XCTAssertNil(CDJSafeAction.verificationProblem(source: adts, converted: remuxed, fileExtension: "m4a"))
    }

    // MARK: Helpers

    private func probe(
        _ codec: String,
        profile: String? = nil,
        rate: Int,
        channels: Int = 2,
        bits: Int? = nil
    ) -> CDJAudioProbe {
        CDJAudioProbe(codec: codec, profile: profile, sampleRateHz: rate, channels: channels, bitsPerRawSample: bits)
    }

    private func issues(_ codec: String, rate: Int, ext: String) -> [CDJIssue] {
        CDJFormatRules.issues(for: probe(codec, rate: rate), fileExtension: ext)
    }

    private func plan(_ probe: CDJAudioProbe, _ ext: String) -> CDJSafeAction {
        CDJSafeAction.plan(for: probe, fileExtension: ext)
    }

    private func wav(_ bits: Int, _ rate: Int) -> CDJSafeAction {
        .convertToWAV(bitDepth: bits, sampleRateHz: rate, downmixToStereo: false)
    }
}
