#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="$PACKAGE_DIR/Artifacts"
ARTIFACT="$ARTIFACTS_DIR/IrohTransportFFI.xcframework"
STAMP_FILE="$ARTIFACTS_DIR/.iroh-ffi-sha256"
LOCK_DIR="$ARTIFACTS_DIR/.fetch.lock"

DEFAULT_URL="https://github.com/bobtheitguy31337/repoprompt-ce/releases/download/iroh-ffi-v0.1.0/IrohTransportFFI.xcframework.zip"
ARTIFACT_URL="${REPOPROMPT_IROH_ARTIFACT_URL:-$DEFAULT_URL}"
EXPECTED_SHA256="${REPOPROMPT_IROH_ARTIFACT_SHA256:-02dfc51f930e8bd7eaa67536363264b1e7a36026f21b2a7ed5322b6b46fc4764}"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--force]" >&2
  exit 64
fi

artifact_ready() {
  [[ -d "$ARTIFACT" && -f "$ARTIFACT/Info.plist" ]] || return 1
  if [[ -f "$STAMP_FILE" ]]; then
    [[ "$(cat "$STAMP_FILE")" == "$EXPECTED_SHA256" ]]
    return $?
  fi
  # Locally built by build-xcframework.sh (no remote stamp).
  return 0
}

if (( ! FORCE )) && artifact_ready; then
  exit 0
fi

mkdir -p "$ARTIFACTS_DIR"

TMP_DIR=""
LOCK_HELD=0
cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  if (( LOCK_HELD )); then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

lock_attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  lock_attempts=$((lock_attempts + 1))
  if (( lock_attempts > 180 )); then
    echo "Timed out waiting for iroh XCFramework fetch lock: $LOCK_DIR" >&2
    exit 1
  fi
  sleep 1
done
LOCK_HELD=1

if (( ! FORCE )) && artifact_ready; then
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iroh-xcframework-fetch.XXXXXX")"
TMP_ZIP="$TMP_DIR/IrohTransportFFI.xcframework.zip"
TMP_EXTRACT="$TMP_DIR/extract"
mkdir -p "$TMP_EXTRACT"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

cached_zip=""
SWIFTPM_CACHE_DIR="$HOME/Library/Caches/org.swift.swiftpm/artifacts"
for candidate in \
  "$SWIFTPM_CACHE_DIR/$EXPECTED_SHA256" \
  "$SWIFTPM_CACHE_DIR/$EXPECTED_SHA256.zip" \
  "$SWIFTPM_CACHE_DIR/IrohTransportFFI.xcframework-$EXPECTED_SHA256.zip"; do
  if [[ -f "$candidate" ]] && [[ "$(sha256_file "$candidate")" == "$EXPECTED_SHA256" ]]; then
    cached_zip="$candidate"
    break
  fi
done

if [[ -n "$cached_zip" ]]; then
  echo "Restoring IrohTransportFFI.xcframework from verified local cache: $cached_zip"
  cp "$cached_zip" "$TMP_ZIP"
else
  echo "Downloading IrohTransportFFI.xcframework via curl from $ARTIFACT_URL"
  curl -fSL --retry 3 --connect-timeout 30 -o "$TMP_ZIP" "$ARTIFACT_URL"
fi

actual_sha256="$(sha256_file "$TMP_ZIP")"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "IrohTransportFFI.xcframework.zip sha256 mismatch: expected $EXPECTED_SHA256, got $actual_sha256" >&2
  exit 1
fi

ditto -x -k "$TMP_ZIP" "$TMP_EXTRACT"
if [[ ! -f "$TMP_EXTRACT/IrohTransportFFI.xcframework/Info.plist" ]]; then
  echo "Extracted archive missing IrohTransportFFI.xcframework/Info.plist" >&2
  exit 1
fi

rm -rf "$ARTIFACT" "$STAMP_FILE"
mv "$TMP_EXTRACT/IrohTransportFFI.xcframework" "$ARTIFACT"

for slice in macos-arm64_x86_64 ios-arm64 ios-arm64_x86_64-simulator; do
  if [[ ! -f "$ARTIFACT/$slice/librepoprompt_iroh_transport.a" ]] \
    || [[ ! -f "$ARTIFACT/$slice/Headers/IrohTransportFFI.h" ]] \
    || [[ ! -f "$ARTIFACT/$slice/Headers/module.modulemap" ]]; then
    echo "Extracted XCFramework missing required slice or headers: $slice" >&2
    rm -rf "$ARTIFACT" "$STAMP_FILE"
    exit 1
  fi
done

printf '%s\n' "$EXPECTED_SHA256" > "$STAMP_FILE"
echo "Prepared $ARTIFACT"
