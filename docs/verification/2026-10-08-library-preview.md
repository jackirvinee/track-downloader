# Library preview without Apple Music — October 8, 2026

Jack explicitly excluded Apple Music access and imports from this task. Library double-click previously opened the file through its default application, which is Music for M4A on the test Mac. It now presents Quick Look for that saved file. No default-application setting is changed. Apple Music access, playback and library imports are outside the acceptance scope.

## Acceptance matrix

| Trigger | Expected visible result | Data/state change | Persistence expectation | Result |
| --- | --- | --- | --- | --- |
| Double-click a saved M4A Library row | Quick Look presents that exact track and duration | Preview reads the saved output; no default-app handoff | Audio file and library organization retained | **PASS** — saved licensed AAC fixture opens in Track Downloader's Quick Look panel, duration 04:46 |
| Preview Play/Pause and seek | Elapsed time advances, pauses and seeks | Preview transport state only | Saved file unchanged | **PASS** — playback advanced to 00:54, Pause changed to off, Skip Forward moved the paused timeline to 01:09; output hash unchanged |
| Escape / preview Close | Preview closes; Library remains usable | Transient preview selection resets | Saved output retained | **PASS** — native Close and Escape from the raised preview panel both return to Library; Space also dismisses the panel |
| Double-click the same row again | Exact track opens in a fresh preview | Transient preview selection updates | Saved output retained | **PASS** — same fixture reopens and plays from 00:00 after dismissal |
| Double-click the saved YouTube Opus row; Pause | Quick Look reads the exact file and its transport advances/pauses | Preview transport state only | Saved output retained | **PASS transport** — previously downloaded Blender fixture advances to 00:15 and pauses; system duration discrepancy recorded below |
| Show in Finder | Exact track is revealed | Finder selection only | Saved output retained | **PASS** — Finder selects the fixture in the isolated test home's Soundcloud folder |
| Quit/relaunch exact fresh app, then double-click | Saved Library track remains and previews | Library rescans durable output | File and library survive restart; preview itself is transient | **PASS** — exact process exited, full bundle relaunch restores Library 1 and double-click presents/plays the same fixture |

## Evidence boundaries

- **PASS source:** 34 focused Swift Library presentation/store tests and 16 bundle identity tests. These checks supplement the rendered journey above.
- **PASS build:** optimized canonical `script/build_and_run.sh --bundle-check`, 17.26 seconds, strict ad-hoc signing verification, isolated installation at `/private/tmp/td-library-preview-install-20261008-1/Applications/Track Downloader.app`.
- **PASS launch/installed identity:** running executable from that exact bundle; Settings displays `Version 1.1.0 (Build 20261008.1)`. Executable SHA-256: `87e62ebe914b3b811f60d80dabb9ddaff613326c98ac834ceee88a51e8e663d3`.
- **PASS rendered/output/persistence:** matrix above, using only a copy of the previously verified licensed SoundCloud output in `/private/tmp/td-library-preview-home-20261008-1`. Saved file remains 5,793,884 bytes with SHA-256 `2608f1007056ee213f953eedb365a2a147cb4f0198a2bac1000d09fae62d3579`. No new provider transfer was needed for this bounded playback change.
- **Apple Music excluded by Jack:** no Music Computer Use request, Music UI interaction or inspection of its library. The system-provided Quick Look “Open with Music” action is excluded from testing and was not clicked; the app's double-click path only presents a preview. Existing installed personal apps and default-file associations were not replaced.
- **PASS additional format transport / known system limitation:** the previously verified licensed YouTube Opus output also opens, advances to 00:15 and pauses in Quick Look. Its hash remains `fe5c6f1f63a9f9baec9503bb929d3c2fcd143ec099df4573d3de45772ae4ccb1`. Quick Look reports duration 11:57 while ffprobe's previously verified duration is 634.600 seconds (10:35). Preview transport proof does not validate that system duration estimate or audio fidelity. No output conversion or rewrite was performed. Other output formats remain unverified.
- **UNVERIFIED clean device/Production:** the isolated local home is not a separate Mac. Trusted signing/notarization, Windows device proof, source merge and publication remain separate gates. The earlier Gatekeeper rejection applies to the ad-hoc development distribution.

The subsequent [October 9 Companion pass](2026-10-09-companion.md) verifies 0.2.1 rendered controls and errors, finds a Space-key collision, and prepares 0.2.2; its final rendered reload check remains unverified. Clean-device installation and trusted distribution remain separate external gates. The earlier real YouTube/SoundCloud download evidence is in [the remaining-gates record](2026-10-06-remaining-gates.md).
