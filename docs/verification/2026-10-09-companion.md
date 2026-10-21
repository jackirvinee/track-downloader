# Companion rendered verification — October 9, 2026

The manually reloaded Companion 0.2.1 was exercised in real Chrome against the licensed Kevin MacLeod SoundCloud track used in the earlier provider journey. This bounded pass found a Space-key collision with SoundCloud's player. Companion 0.2.2 adds focused-button capture for that press, including key release and repeat after the button loses focus. Other controls and Enter retain their normal keyboard behavior. Permissions and native-host protocol are unchanged.

## Acceptance matrix

| Trigger | Expected visible result | State change | Persistence | Evidence |
| --- | --- | --- | --- | --- |
| SoundCloud track page, iframe layout | Page Queue button appears | Supported item identified | Recreated on navigation | PASS on 0.2.1 |
| Click page Queue | Request enters persistent native queue, without media transfer | One real licensed URL stored | Retained across page reload | PASS on 0.2.1; isolated queue count 1 |
| Reload then Enter on page button | Already queued | No duplicate | Existing request retained | PASS on 0.2.1 |
| Space on focused page button | Queues once without playing site audio | Same handoff as click | Request retained | FAIL on 0.2.1; 0.2.2 source regression checks PASS, final rendered check UNVERIFIED pending manual reload |
| Popup click / Tab then Space or Enter | Queued or already waiting | Exactly one request | Native file retained | PASS on 0.2.1; fresh isolated keyboard queue count 1 |
| Escape from popup | Popup dismisses | Transient UI only | Queue retained | PASS on 0.2.1 |
| Navigate to SoundCloud artist page | No page Queue button; popup asks for an individual video/track | No enqueue | Existing queue count unchanged | PASS on 0.2.1 |
| Queue at capacity through page or popup | Queue full; review in app | No 21st request | All 20 retained | PASS on 0.2.1; controlled protocol fixtures, no fixture media downloaded |
| Missing native host, page/popup | Failure visible and retry enabled | No new request | Existing requests retained | PASS on 0.2.1: page “Couldn’t queue—try again”, popup “Native host has exited.” |
| Restore host then retry same controls | Already queued | Successful real host response; no duplicate | Existing request retained | PASS on 0.2.1 |
| YouTube page and final 0.2.2 browser coverage | Correct rendered control/handoff | Real request | Persistent queue | UNVERIFIED in this final pass; earlier provider/output proof remains separate |
| Chrome quit/relaunch | Queue survives and Companion works | Relaunched browser | Requests retained | UNVERIFIED; Chrome availability question pending |
| Today’s browser request through native app to saved output and relaunch | Real queue consumed explicitly, saved file in Library | App-driven download | Output retained | UNVERIFIED in this pass; earlier full native/output journeys remain in previous records |

## Evidence boundaries

- PASS source: 22 extension tests, including four Space collision regressions. These are supplemental source evidence, not rendered proof of 0.2.2.
- PASS native-host identity: reused the exact October 8 build 1.1.0 / 20261008.1 host; native executable SHA-256 remains `87e62ebe914b3b811f60d80dabb9ddaff613326c98ac834ceee88a51e8e663d3`. This JS-only follow-up produces no new native build.
- PASS isolation/restoration: three isolated homes retained real requests and controlled capacity fixtures. No media transfer occurred in this pass. Chrome registration was restored byte-for-byte to its original manifest, SHA-256 `4bf5b17f5e4800c1cc155fb90f43772e61218d950e9b4f4a2dc249de163b9ec7`.
- SoundCloud captured Space during the failed keyboard test and briefly played its existing site miniplayer; the player was paused afterward. No social action or playlist change was made.
- Apple Music access and imports remain explicitly excluded. Existing Quick Look proof is in [the Library preview record](2026-10-08-library-preview.md).
- UNVERIFIED final rendered gate: manual reload of prepared Companion 0.2.2 is required. The whole browser gate is not complete.
- UNVERIFIED clean Mac/Windows device and Production. Trusted signing/notarization and publication remain external gates; the earlier ad-hoc Gatekeeper distribution FAIL still applies.
