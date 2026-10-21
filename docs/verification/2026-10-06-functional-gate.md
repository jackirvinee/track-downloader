# Queue functional gate — October 6, 2026

October 8 scope correction: Jack excludes Apple Music access and imports. The historical Music-access requirement is superseded by [verified Library Quick Look preview](2026-10-08-library-preview.md) in build `20261008.1`.

**PASS: native paste → source review → explicit Download → saved audio → Library → Finder/Quick Look preview → quit/relaunch.** This is a bounded local SoundCloud journey, not a complete app, browser, YouTube, clean-device, or release qualification.

Source baseline: PR #9 at `4de8f2f`. Final local build: **1.1.0 (`20261006.2`)**. Build `20261006.1` exposed the two failures below and is superseded. Each build used a fresh isolated home, queue, output folder, and Applications directory under `/private/tmp`; no personal app bundle, queue, or library was replaced. Test files and queues are retained outside the repository.

Test source: [Despair And Triumph by Kevin MacLeod](https://soundcloud.com/kevin-9-1/despair-and-triumph). The artist upload explicitly states CC BY 3.0 and `License: cc-by`; [artist source](https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1400012). Attribution: Despair and Triumph — Kevin MacLeod (incompetech.com), CC BY 3.0. Deliberately nonexistent SoundCloud paths under that artist were used to exercise errors without downloading other media.

## Failures found and corrected

1. **Library selection: FAIL → PASS.** The downloader and scanner can identify the same file using different spellings of a symlinked output path. Selecting the downloader URL before the asynchronous scan completed left the Library row unselected. Selection now waits for the current scan, matches the resolved file, and uses the actual catalogue URL. Build `20261006.2` automatically selected the real completed track and displayed its detail panel, artwork, waveform, and exact path. A regression test covers a real output-folder alias.
2. **Archive retry: FAIL → PASS.** `--print` implicitly enabled yt-dlp quiet mode, hiding the archive-skip diagnostic that the existing service needs. A retry incorrectly reported that no audio file was found. Explicit `--no-quiet` preserves that evidence. The real retry now says no new file was created and directs the user to the local collection; the saved file hash and count remain unchanged. This uses yt-dlp's documented [verbosity behavior](https://github.com/yt-dlp/yt-dlp#verbosity-and-simulation-options).

## Visible-interaction acceptance matrix

Scope: the changed queue completion/retry flow and its input, batch, Library, file-opening, and persistence dependencies. Unchanged Settings preferences, crates, columns, unrelated browser controls, and proposed features are outside this bounded check.

| Trigger | Expected visible result | Data/state change | Persistence | Evidence |
| --- | --- | --- | --- | --- |
| Fresh launch and Settings → Escape | Empty test Library/queue; correct version/build; return to source | Exact optimized app uses isolated home | Same home across relaunch | **PASS** — Library 0, Queue 0/20, isolated output; Settings `Version 1.1.0 (Build 20261006.2)` |
| Paste licensed supported link | Input clears; ready row shows title, duration, estimate and explicit Download | URL durable before clearing; inspection only | Row survives relaunch; no audio until Download | **PASS** — title/creator, 4:46, 160 kbps est.; queue JSON written and zero audio files before transfer |
| Duplicate/unsupported input; typed Return | Duplicate notice; unsupported input retained; Return uses the same queue | No duplicate or unintended download | Existing row retained | **PASS** — queue stays 1/20; unsupported URL remains editable; typed duplicate clears with notice |
| Clear Queue → Cancel | Confirmation explains removal; Cancel dismisses without changing rows | None | Queue retained | **PASS** — confirmed retained queue; actual destructive clearing was not performed |
| Quit before Download and relaunch | Same pending row restored and checked; explicit Download still required | No automatic media transfer | Durable queue | **PASS** — queue 1/20, Library 0 and no audio before explicit Download |
| Explicit per-item Download | Real transfer stages; successful row removed; saved track selected with details | Actual downloader, sidecar, archive, quality report and Library scan | Audio and Library survive relaunch | **PASS** — automatic selection verified on final build; real file decoded and measured |
| Refresh/select/search; Clear Search | Real track remains; artist search matches; no-match state and Clear Search recover list | Actual catalogue scan/filter/selection | File retained | **PASS** — `kevin` matches; no-match notice; Clear Search and Refresh restore the track |
| Show in Finder → Space / native preview / pause | Exact saved file revealed; Quick Look plays and pauses | Reads real saved audio | File retained | **PASS** — exact isolated file selected; duration 4:46; elapsed time advanced to 00:08 and remained stopped after pause |
| Open Downloads | Correct output folder opens in Finder | No move/rename | File retained | **PASS** — isolated Track Downloader output folder with Soundcloud, log and quality report |
| Download All → Cancel; Escape | Explicit serial batch; current operation stops; unfinished rows retained | Cancellation of actual source-check operation | Unfinished queue retained | **PASS** — both Cancel button and Escape restored idle controls with 2/20 retained |
| Download All with failed source; add link during batch | First failure retained; next row processed; new arrival waits outside snapshot | Real provider check and archive skip; no media for new arrival | Failed and waiting states persisted | **PASS** — missing source failed, archived source produced correct history notice; new arrival stayed queued |
| Check again on failed source | Real inspection returns actionable failure/retry control | Failed row retained | Queue retained | **PASS** — real nonexistent-source inspection returns Check again; no audio created |
| Quit after output; relaunch | Saved Library track, artwork/waveform and remaining queue restored; no auto-download | Files scan; queue restored | Durable home/queue/output | **PASS** — Library 1 and queue 3/20 (two failed, one waiting); saved audio unchanged |
| Library double-click → default Music app | Default audio app opens exact file and supports play/stop | External application handoff | File retained | **UNVERIFIED** — Music computer-use access was not approved. Finder/Quick Look playback above closes the bounded output-preview journey. |

Actual Clear Queue removal is **UNVERIFIED**: the user-provided Destruction Guardrail requires fresh approval for an exact deletion target. No records were cleared. No cancellation during a sustained media transfer or interrupted-transfer resume claim is made; cancellation was exercised during the real source-check stage.

## Evidence boundaries

| Boundary | Status and evidence |
| --- | --- |
| Source tests | **PASS** — 71 focused Swift tests covering command builder, downloaded-track store, downloader service and queue store; 16 identity tests; 9 parity tests; parity catalogue validator and diff check |
| Build | **PASS** — optimized canonical `script/build_and_run.sh --bundle-check`, fresh build/install roots; strict ad-hoc signature verification |
| Launch / installed test build | **PASS** — `open -n --env CFFIXED_USER_HOME=…` launched the same fresh bundle; process path and Settings identity checked. No personal installed bundle updated. |
| Rendered interactions | **PASS** for matrix items above; default-app Music preview separately **UNVERIFIED** |
| Persistence | **PASS** — pending queue before transfer, saved audio and 3 unfinished queue rows after full quit/relaunch; no automatic media download |
| Output artifact | **PASS** — M4A/AAC stereo, 44,100 Hz, audio-stream bitrate 160,005 bit/s, duration 285.712222 s, 5,793,884 bytes; ffmpeg full decode exits 0; sidecar, embedded title/artist/genre/artwork, source URL and archive verified |
| Provider | **PASS** for the selected licensed SoundCloud upload only. Current YouTube download is **UNVERIFIED**; the earlier licensed YouTube attempt's HTTP 403 remains unresolved. |
| Physical / other device | **UNVERIFIED** — no second/clean Mac, Windows UI or DJ device qualification |
| Production / distribution | **UNVERIFIED** — no source merge, public visibility change, packaged release, Developer ID/notarization or publication |

Saved audio SHA-256: `2608f1007056ee213f953eedb365a2a147cb4f0198a2bac1000d09fae62d3579`.

Final test executable SHA-256: `553539e493013b946539b2427b2b1a6a30bbb4439db4882e070530bf4de999dc`.

Final test bundle: `/private/tmp/td-functional-install-20261006-2/Applications/Track Downloader.app`. Isolated home/output/queue: `/private/tmp/td-functional-home-20261006-2`.

## Remaining limits

The Library Quality column currently shows `—`; this check measured the saved file using the real ffprobe/report pipeline and does not claim a per-track quality display. Source estimates remain distinct from saved-file measurements. Archived links remain in the queue with an explicit history notice rather than inventing a fresh success or file path.

Music double-click playback needs approved Music computer-use access and a verified isolated Music library before exercising play/stop. Browser popup/SoundCloud handoff/browser-relaunch, a successful YouTube download, and full release/device checks remain separate gates. Native Chrome registration was not changed.

Personal preservation check: the original Queue app executable hash, personal queue-file hash, and all 26 personal library/output files' paths, sizes and modification times matched the pre-test baseline. Personal filenames and baseline data stay outside the repository. No proposed Settings, queue redesign, folder, browser activation or backup feature was implemented.

October 6 follow-up: the [remaining-gates record](2026-10-06-remaining-gates.md) supersedes the YouTube uncertainty above with a successful real transfer after updating the existing extractor. It records fresh build 20261006.3, installed Chrome popup/native output evidence, browser source fixes awaiting manual reload, and the unresolved Music access, clean-device and distribution gates.
