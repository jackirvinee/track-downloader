#!/usr/bin/env bash
set -euo pipefail

TRACK_DOWNLOADER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACK_DOWNLOADER_APP="${TRACK_DOWNLOADER_APP:-$HOME/Applications/Track Downloader.app}"
TRACK_DOWNLOADER_HOST_NAME="com.jackirvine.trackdownloader.chrome"
TRACK_DOWNLOADER_HOST_BINARY="$TRACK_DOWNLOADER_APP/Contents/Resources/TrackDownloaderChromeHost"
TRACK_DOWNLOADER_HOST_DIRECTORY="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
TRACK_DOWNLOADER_HOST_MANIFEST="$TRACK_DOWNLOADER_HOST_DIRECTORY/$TRACK_DOWNLOADER_HOST_NAME.json"
TRACK_DOWNLOADER_TEMPLATE="$TRACK_DOWNLOADER_ROOT/chrome-extension/native-host-manifest.json"

fail() {
  echo "Track Downloader Chrome companion: $*" >&2
  exit 1
}

if [[ $# -gt 1 || "${1:-}" == "--help" ]]; then
  fail "usage: $0 [--print-manifest]"
fi

if [[ ! -d "$TRACK_DOWNLOADER_APP" || ! -x "$TRACK_DOWNLOADER_HOST_BINARY" ]]; then
  fail "build and install Track Downloader first; missing native host at $TRACK_DOWNLOADER_HOST_BINARY"
fi

TRACK_DOWNLOADER_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$TRACK_DOWNLOADER_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$TRACK_DOWNLOADER_BUNDLE_ID" != "com.jackirvine.trackdownloader" ]]; then
  fail "expected the Track Downloader app bundle"
fi

TRACK_DOWNLOADER_STAGED_MANIFEST="${TMPDIR:-/tmp}/$TRACK_DOWNLOADER_HOST_NAME.$$.json"
cleanup() {
  rm -f "$TRACK_DOWNLOADER_STAGED_MANIFEST"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
manifest["path"] = sys.argv[3]
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(manifest, destination, indent=2)
    destination.write("\n")
' "$TRACK_DOWNLOADER_TEMPLATE" "$TRACK_DOWNLOADER_STAGED_MANIFEST" "$TRACK_DOWNLOADER_HOST_BINARY"

if [[ "${1:-}" == "--print-manifest" ]]; then
  cat "$TRACK_DOWNLOADER_STAGED_MANIFEST"
  exit 0
fi

mkdir -p "$TRACK_DOWNLOADER_HOST_DIRECTORY"
mv "$TRACK_DOWNLOADER_STAGED_MANIFEST" "$TRACK_DOWNLOADER_HOST_MANIFEST"
trap - EXIT HUP INT TERM
echo "Registered $TRACK_DOWNLOADER_HOST_MANIFEST"
echo "In Chrome, open chrome://extensions, enable Developer mode, then Load unpacked:"
echo "$TRACK_DOWNLOADER_ROOT/chrome-extension"
