# Contributing to Track Downloader

Thanks for helping improve Track Downloader. Small, well-tested changes are easiest to review. `TrackDownloader` remains the internal Swift module and Python package name in some paths and commands.

## Before opening an issue

- Search existing issues first.
- State your macOS version, Track Downloader commit, `yt-dlp --version`, and `ffmpeg -version`.
- Remove URLs, cookies, account names, download logs, and other personal data from reports.
- Do not report security vulnerabilities in a public issue; follow [SECURITY.md](SECURITY.md).

## Development workflow

1. Create a focused branch from `main`.
2. Make one coherent change with tests where practical.
3. Run both test suites:

   ```bash
   CLANG_MODULE_CACHE_PATH=/tmp/track-downloader-clang-cache \
   SWIFTPM_MODULECACHE_OVERRIDE=/tmp/track-downloader-swiftpm-cache \
   swift test --disable-sandbox
   python3 -m unittest
   ```

4. Explain what changed, why, and how you tested it in the pull request.

## Project boundaries

- Track Downloader supports only content the user is authorized to access.
- Never commit downloaded media, browser cookies, API keys, personal logs, or account data.
- Do not add test fixtures sourced from copyrighted media. Generate minimal local fixtures instead.
- Keep the native app focused on a reliable single-link download flow; discuss larger UX changes in an issue before implementing them.
- Treat changes to workflows, build/install scripts, executable resolution, cookie access, URL validation, output containment, signing, and releases as security-sensitive.
- Fork pull requests must run on GitHub-hosted runners without maintainer secrets. Do not introduce `pull_request_target` execution of fork-controlled code.

By contributing, you agree that your contributions may be distributed under the MIT License.
