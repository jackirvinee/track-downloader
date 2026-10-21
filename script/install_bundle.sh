#!/usr/bin/env bash
set -euo pipefail

TRACK_DOWNLOADER_BUNDLE_ID="com.jackirvine.trackdownloader"
TRACK_DOWNLOADER_PRODUCT_NAME="Track Downloader"
TRACK_DOWNLOADER_SOURCE_BUNDLE="${1:-}"
TRACK_DOWNLOADER_INSTALL_ROOT="${2:-${TRACK_DOWNLOADER_INSTALL_ROOT:-$HOME/Applications}}"

fail() {
  echo "Track Downloader install: $*" >&2
  exit 1
}

clean_bundle_root_metadata() {
  local bundle="$1"
  xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
}

if [[ $# -gt 2 || -z "$TRACK_DOWNLOADER_SOURCE_BUNDLE" ]]; then
  fail "usage: $0 SOURCE_BUNDLE [INSTALL_ROOT]"
fi

if [[ "$TRACK_DOWNLOADER_INSTALL_ROOT" != /* ]]; then
  fail "unsafe install root: use an absolute Applications directory"
fi

# Only an Applications directory is an intended destination. This accepts
# temporary /.../Applications roots for controlled verification while
# preventing accidental replacement directly in a broad parent directory.
if [[ "$TRACK_DOWNLOADER_INSTALL_ROOT" == "/" || "$TRACK_DOWNLOADER_INSTALL_ROOT" == "$HOME" || "$(basename "$TRACK_DOWNLOADER_INSTALL_ROOT")" != "Applications" ]]; then
  fail "unsafe install root: expected an Applications directory"
fi

if [[ ! -d "$TRACK_DOWNLOADER_SOURCE_BUNDLE" || "$(basename "$TRACK_DOWNLOADER_SOURCE_BUNDLE")" != *.app ]]; then
  fail "source is not an app bundle: $TRACK_DOWNLOADER_SOURCE_BUNDLE"
fi

TRACK_DOWNLOADER_INFO_PLIST="$TRACK_DOWNLOADER_SOURCE_BUNDLE/Contents/Info.plist"
if [[ ! -f "$TRACK_DOWNLOADER_INFO_PLIST" ]]; then
  fail "source app bundle is missing Contents/Info.plist"
fi

TRACK_DOWNLOADER_SOURCE_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$TRACK_DOWNLOADER_INFO_PLIST" 2>/dev/null || true)"
if [[ "$TRACK_DOWNLOADER_SOURCE_BUNDLE_ID" != "$TRACK_DOWNLOADER_BUNDLE_ID" ]]; then
  fail "source bundle identifier must be $TRACK_DOWNLOADER_BUNDLE_ID"
fi

mkdir -p "$TRACK_DOWNLOADER_INSTALL_ROOT"
TRACK_DOWNLOADER_INSTALL_ROOT="$(cd "$TRACK_DOWNLOADER_INSTALL_ROOT" && pwd -P)"
if [[ "$TRACK_DOWNLOADER_INSTALL_ROOT" == "/" || "$TRACK_DOWNLOADER_INSTALL_ROOT" == "$HOME" || "$(basename "$TRACK_DOWNLOADER_INSTALL_ROOT")" != "Applications" ]]; then
  fail "unsafe install root: expected an Applications directory"
fi

TRACK_DOWNLOADER_TARGET_BUNDLE="$TRACK_DOWNLOADER_INSTALL_ROOT/$TRACK_DOWNLOADER_PRODUCT_NAME.app"
TRACK_DOWNLOADER_STAGE_BUNDLE="$TRACK_DOWNLOADER_INSTALL_ROOT/.$TRACK_DOWNLOADER_PRODUCT_NAME.app.staging"
TRACK_DOWNLOADER_BACKUP_BUNDLE="$TRACK_DOWNLOADER_INSTALL_ROOT/.$TRACK_DOWNLOADER_PRODUCT_NAME.app.backup"
TRACK_DOWNLOADER_BACKUP_ACTIVE=false
TRACK_DOWNLOADER_NEW_TARGET_MOVED=false
TRACK_DOWNLOADER_INSTALL_COMPLETE=false

cleanup_or_restore_previous_release() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$TRACK_DOWNLOADER_INSTALL_COMPLETE" != true ]]; then
    # The backup's existence is the durable swap marker: it also covers a
    # signal delivered in the small interval immediately after `mv`.
    if [[ -e "$TRACK_DOWNLOADER_BACKUP_BUNDLE" ]]; then
      if [[ -e "$TRACK_DOWNLOADER_TARGET_BUNDLE" ]]; then
        rm -rf "$TRACK_DOWNLOADER_TARGET_BUNDLE"
      fi
      mv "$TRACK_DOWNLOADER_BACKUP_BUNDLE" "$TRACK_DOWNLOADER_TARGET_BUNDLE"
    elif [[ "$TRACK_DOWNLOADER_BACKUP_ACTIVE" != true && "$TRACK_DOWNLOADER_NEW_TARGET_MOVED" == true && -e "$TRACK_DOWNLOADER_TARGET_BUNDLE" ]]; then
      rm -rf "$TRACK_DOWNLOADER_TARGET_BUNDLE"
    fi
  fi
  rm -rf "$TRACK_DOWNLOADER_STAGE_BUNDLE"
  exit "$status"
}

trap cleanup_or_restore_previous_release EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_install_test_hook() {
  if [[ "${TRACK_DOWNLOADER_INSTALL_TESTING:-}" != "1" ]]; then
    return 0
  fi

  case "${TRACK_DOWNLOADER_INSTALL_TEST_HOOK:-}" in
    "")
      ;;
    after-backup)
      echo "Track Downloader install: controlled after-backup failure" >&2
      return 1
      ;;
    hold-after-backup)
      while true; do
        sleep 1
      done
      ;;
    *)
      fail "unknown controlled installer test hook"
      ;;
  esac
}

# Recover only this installer's exact prior backup before starting a new swap.
if [[ -e "$TRACK_DOWNLOADER_BACKUP_BUNDLE" ]]; then
  clean_bundle_root_metadata "$TRACK_DOWNLOADER_BACKUP_BUNDLE"
  if ! /usr/bin/codesign --verify --deep --strict "$TRACK_DOWNLOADER_BACKUP_BUNDLE"; then
    # Keep a current target intact if an orphaned backup cannot be trusted.
    TRACK_DOWNLOADER_INSTALL_COMPLETE=true
    fail "prior backup failed strict signature verification"
  fi
  if [[ -e "$TRACK_DOWNLOADER_TARGET_BUNDLE" ]]; then
    rm -rf "$TRACK_DOWNLOADER_TARGET_BUNDLE"
  fi
  mv "$TRACK_DOWNLOADER_BACKUP_BUNDLE" "$TRACK_DOWNLOADER_TARGET_BUNDLE"
fi

# These are fixed paths under the validated Applications root, never globs.
rm -rf "$TRACK_DOWNLOADER_STAGE_BUNDLE"
/usr/bin/ditto --rsrc --extattr "$TRACK_DOWNLOADER_SOURCE_BUNDLE" "$TRACK_DOWNLOADER_STAGE_BUNDLE"
clean_bundle_root_metadata "$TRACK_DOWNLOADER_STAGE_BUNDLE"
if ! /usr/bin/codesign --verify --deep --strict "$TRACK_DOWNLOADER_STAGE_BUNDLE"; then
  fail "staged bundle failed strict signature verification"
fi

if [[ -e "$TRACK_DOWNLOADER_TARGET_BUNDLE" ]]; then
  rm -rf "$TRACK_DOWNLOADER_BACKUP_BUNDLE"
  mv "$TRACK_DOWNLOADER_TARGET_BUNDLE" "$TRACK_DOWNLOADER_BACKUP_BUNDLE"
  TRACK_DOWNLOADER_BACKUP_ACTIVE=true
fi

if ! run_install_test_hook; then
  fail "controlled installer test hook failed"
fi

mv "$TRACK_DOWNLOADER_STAGE_BUNDLE" "$TRACK_DOWNLOADER_TARGET_BUNDLE"
TRACK_DOWNLOADER_NEW_TARGET_MOVED=true
if ! /usr/bin/codesign --verify --deep --strict "$TRACK_DOWNLOADER_TARGET_BUNDLE"; then
  fail "installed bundle failed strict signature verification"
fi

if [[ "$TRACK_DOWNLOADER_BACKUP_ACTIVE" == true ]]; then
  rm -rf "$TRACK_DOWNLOADER_BACKUP_BUNDLE"
fi
TRACK_DOWNLOADER_INSTALL_COMPLETE=true
echo "Installed $TRACK_DOWNLOADER_TARGET_BUNDLE"
