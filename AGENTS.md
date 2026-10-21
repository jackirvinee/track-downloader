# Track Downloader Build Versioning

For every user-visible Track Downloader build, keep `CFBundleShortVersionString` as the semantic release version and set `CFBundleVersion` to `YYYYMMDD.N`, using the current date in `America/Toronto` and incrementing `N` for each distinct build produced that day.

Before choosing `N`, inspect the relevant Track Downloader source worktree, active Track Downloader branches or pull requests, and the installed Track Downloader.app bundle. Use the next unused sequence number and never reuse one build identifier for different source.

Display the identifier in Settings beside Check for Updates as `Version X.Y.Z (Build YYYYMMDD.N)`. Update the bundle identity test whenever the build identifier changes. Do not renumber historical commits or imply that a local build is a published release.
