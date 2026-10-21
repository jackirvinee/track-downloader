# Design QA

## Target

- Reference: selected `codex-clipboard-efca39a9-6b0d-466b-98bc-651e460496ad.png` mockup.
- Implemented state: macOS Light appearance, `downloading` fixture, 68% progress, Reduce Motion enabled.
- Comparison: reference and a window-only app capture were normalized to the same height and reviewed side by side.

## Visible checks

- Passed: the VU meter is inside the active Source transfer region, below the title, stage, progress facts, and Cancel action.
- Passed: the meter spans the usable Source-pane width and forms the visual footer immediately above Queue & Recent.
- Passed: the rail stays flat within the native pane hierarchy; no card, dashboard, or decorative container was added.
- Passed: the 68% state is visually legible in addition to the segmented meter, so progress does not rely on colour.
- Passed: the existing resizable Source/Library split, toolbar, table, history, output, and status-bar hierarchy remains intact.
- Intentional difference: the deterministic fixture uses generic local metadata and no remote artwork. Production shows the sanitized preflight title when one is available.
- Intentional difference: the restored production VU component keeps its 26-segment resolution rather than copying the mockup's approximate segment count.

## Accessibility and motion

- Accessibility inspection exposes the rail as `Download progress` with value `68%`.
- Indeterminate stages use a moving three-segment window; Reduce Motion replaces it with a stable centered window.

final result: passed
