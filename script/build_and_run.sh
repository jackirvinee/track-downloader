#!/usr/bin/env bash
set -euo pipefail

TRACK_DOWNLOADER_MODE="${1:-run}"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--bundle-check]" >&2
}
fail_build_root() {
  echo "unsafe build root: use a directory inside TMPDIR" >&2
  exit 2
}


if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "$TRACK_DOWNLOADER_MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--bundle-check|bundle-check)
    ;;
  *)
    usage
    exit 2
    ;;
esac

TRACK_DOWNLOADER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACK_DOWNLOADER_APP_NAME="TrackDownloader"
TRACK_DOWNLOADER_PRODUCT_NAME="Track Downloader"
TRACK_DOWNLOADER_BUNDLE_ID="com.jackirvine.trackdownloader"
TRACK_DOWNLOADER_INSTALL_ROOT="${TRACK_DOWNLOADER_INSTALL_ROOT:-$HOME/Applications}"
TRACK_DOWNLOADER_TEMP_ROOT="${TMPDIR:-/tmp}"
TRACK_DOWNLOADER_TEMP_ROOT="${TRACK_DOWNLOADER_TEMP_ROOT%/}"
if [[ -z "$TRACK_DOWNLOADER_TEMP_ROOT" ]]; then
  TRACK_DOWNLOADER_TEMP_ROOT="/"
fi
TRACK_DOWNLOADER_BUILD_ROOT="${TRACK_DOWNLOADER_BUILD_ROOT:-$TRACK_DOWNLOADER_TEMP_ROOT/track-downloader-swift-build}"

if [[ "$TRACK_DOWNLOADER_TEMP_ROOT" != /* || "$TRACK_DOWNLOADER_TEMP_ROOT" == "/" || "$TRACK_DOWNLOADER_BUILD_ROOT" != "$TRACK_DOWNLOADER_TEMP_ROOT/"* ]]; then
  fail_build_root
fi

TRACK_DOWNLOADER_TEMP_ROOT="$(cd "$TRACK_DOWNLOADER_TEMP_ROOT" && pwd -P)"
mkdir -p "$TRACK_DOWNLOADER_BUILD_ROOT"
TRACK_DOWNLOADER_BUILD_ROOT="$(cd "$TRACK_DOWNLOADER_BUILD_ROOT" && pwd -P)"
if [[ "$TRACK_DOWNLOADER_BUILD_ROOT" != "$TRACK_DOWNLOADER_TEMP_ROOT/"* ]]; then
  fail_build_root
fi

TRACK_DOWNLOADER_SWIFTPM_BUILD_PATH="$TRACK_DOWNLOADER_BUILD_ROOT/swiftpm"
TRACK_DOWNLOADER_CLANG_CACHE="$TRACK_DOWNLOADER_BUILD_ROOT/clang-module-cache"
TRACK_DOWNLOADER_SWIFTPM_CACHE="$TRACK_DOWNLOADER_BUILD_ROOT/swiftpm-module-cache"
TRACK_DOWNLOADER_SOURCE_APP_BUNDLE="$TRACK_DOWNLOADER_ROOT/$TRACK_DOWNLOADER_PRODUCT_NAME.app"
TRACK_DOWNLOADER_APP_BUNDLE="$TRACK_DOWNLOADER_BUILD_ROOT/$TRACK_DOWNLOADER_PRODUCT_NAME.app"
TRACK_DOWNLOADER_APP_BINARY="$TRACK_DOWNLOADER_APP_BUNDLE/Contents/MacOS/$TRACK_DOWNLOADER_APP_NAME"
TRACK_DOWNLOADER_CHROME_HOST_BINARY="$TRACK_DOWNLOADER_APP_BUNDLE/Contents/Resources/TrackDownloaderChromeHost"
TRACK_DOWNLOADER_RUNTIME_APP_BUNDLE="$TRACK_DOWNLOADER_APP_BUNDLE"
TRACK_DOWNLOADER_RUNTIME_APP_BINARY="$TRACK_DOWNLOADER_APP_BINARY"

clean_bundle_root_metadata() {
  # Keep signing deterministic without removing arbitrary extended attributes.
  # Finder and FileProvider can restore these exact bundle-root attributes.
  xattr -d com.apple.FinderInfo "$TRACK_DOWNLOADER_APP_BUNDLE" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$TRACK_DOWNLOADER_APP_BUNDLE" 2>/dev/null || true
}

if [[ -z "${TRACK_DOWNLOADER_BUILD_CONFIGURATION:-}" ]]; then
  case "$TRACK_DOWNLOADER_MODE" in
    --debug|debug)
      TRACK_DOWNLOADER_BUILD_CONFIGURATION="debug"
      ;;
    *)
      TRACK_DOWNLOADER_BUILD_CONFIGURATION="release"
      ;;
  esac
fi

mkdir -p "$TRACK_DOWNLOADER_CLANG_CACHE" "$TRACK_DOWNLOADER_SWIFTPM_CACHE"
rm -rf "$TRACK_DOWNLOADER_APP_BUNDLE"
/usr/bin/ditto --rsrc --extattr "$TRACK_DOWNLOADER_SOURCE_APP_BUNDLE" "$TRACK_DOWNLOADER_APP_BUNDLE"
mkdir -p "$TRACK_DOWNLOADER_APP_BUNDLE/Contents/MacOS"

CLANG_MODULE_CACHE_PATH="$TRACK_DOWNLOADER_CLANG_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$TRACK_DOWNLOADER_SWIFTPM_CACHE" \
swift build --disable-sandbox --build-path "$TRACK_DOWNLOADER_SWIFTPM_BUILD_PATH" -c "$TRACK_DOWNLOADER_BUILD_CONFIGURATION"

TRACK_DOWNLOADER_BUILD_DIRECTORY="$(
  CLANG_MODULE_CACHE_PATH="$TRACK_DOWNLOADER_CLANG_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$TRACK_DOWNLOADER_SWIFTPM_CACHE" \
  swift build --disable-sandbox --build-path "$TRACK_DOWNLOADER_SWIFTPM_BUILD_PATH" -c "$TRACK_DOWNLOADER_BUILD_CONFIGURATION" --show-bin-path
)"

cp "$TRACK_DOWNLOADER_BUILD_DIRECTORY/$TRACK_DOWNLOADER_APP_NAME" "$TRACK_DOWNLOADER_APP_BINARY"
chmod +x "$TRACK_DOWNLOADER_APP_BINARY"
cp "$TRACK_DOWNLOADER_BUILD_DIRECTORY/TrackDownloaderChromeHost" "$TRACK_DOWNLOADER_CHROME_HOST_BINARY"
chmod +x "$TRACK_DOWNLOADER_CHROME_HOST_BINARY"
plutil -lint "$TRACK_DOWNLOADER_APP_BUNDLE/Contents/Info.plist" >/dev/null
clean_bundle_root_metadata
if ! codesign --force --deep --sign - "$TRACK_DOWNLOADER_APP_BUNDLE" >/dev/null; then
  # FileProvider can restore these exact root attributes between cleanup and
  # signing. Retry once after removing only those attributes again.
  clean_bundle_root_metadata
  codesign --force --deep --sign - "$TRACK_DOWNLOADER_APP_BUNDLE" >/dev/null
fi
# Finder or FileProvider metadata can be restored while staging or signing.
# Remove only these exact bundle-root attributes before strict verification.
clean_bundle_root_metadata
codesign --verify --deep --strict "$TRACK_DOWNLOADER_APP_BUNDLE"

if [[ "$TRACK_DOWNLOADER_BUILD_CONFIGURATION" == "release" && "$TRACK_DOWNLOADER_MODE" != "--debug" && "$TRACK_DOWNLOADER_MODE" != "debug" ]]; then
  "$TRACK_DOWNLOADER_ROOT/script/install_bundle.sh" "$TRACK_DOWNLOADER_APP_BUNDLE" "$TRACK_DOWNLOADER_INSTALL_ROOT"
  TRACK_DOWNLOADER_RUNTIME_APP_BUNDLE="${TRACK_DOWNLOADER_INSTALL_ROOT%/}/$TRACK_DOWNLOADER_PRODUCT_NAME.app"
  TRACK_DOWNLOADER_RUNTIME_APP_BINARY="$TRACK_DOWNLOADER_RUNTIME_APP_BUNDLE/Contents/MacOS/$TRACK_DOWNLOADER_APP_NAME"
fi

open_track_downloader() {
  /usr/bin/open -n "$TRACK_DOWNLOADER_RUNTIME_APP_BUNDLE"
}

case "$TRACK_DOWNLOADER_MODE" in
  run)
    open_track_downloader
    ;;
  --debug|debug)
    lldb -- "$TRACK_DOWNLOADER_RUNTIME_APP_BINARY"
    ;;
  --logs|logs)
    open_track_downloader
    /usr/bin/log stream --info --style compact --predicate "process == \"$TRACK_DOWNLOADER_APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_track_downloader
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$TRACK_DOWNLOADER_BUNDLE_ID\""
    ;;
  --verify|verify)
    open_track_downloader
    sleep 2
    pgrep -x "$TRACK_DOWNLOADER_APP_NAME" >/dev/null
    ;;
  --bundle-check|bundle-check)
    # Builds and verifies the local bundle without opening a GUI window.
    ;;
esac
