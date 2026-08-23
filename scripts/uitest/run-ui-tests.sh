#!/usr/bin/env bash
#
# Drives LyraUITests against a booted simulator and a local mock WebDAV server.
#
# The tests are grouped rather than run in one pass because they need different
# server states: one group wants a fast server, one a deliberately slow one so
# the scan progress card can be photographed, and the offline-first pair needs
# the server stopped between its two steps.
#
# Screenshots land in $EVIDENCE (default build/uitest-evidence).
set -euo pipefail

cd "$(dirname "$0")/../.."

DEVICE="${DEVICE:-iPhone 17}"
PORT="${PORT:-8099}"
MEDIA="${MEDIA:-build/uitest-media}"
EVIDENCE="${EVIDENCE:-build/uitest-evidence}"
DD="${DD:-build/uitest-dd}"
APP="$DD/Build/Products/Debug-iphonesimulator/Lyra.app"
BUNDLE_ID="care.davinci.lyra"
SERVER_PID=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

start_server() {
  cleanup
  local delay="${1:-0}" logfile="$2"
  LYRA_DAV_DELAY="$delay" python3 scripts/uitest/mock-webdav-server.py \
    "$MEDIA/remote" "$PORT" "$logfile" &
  SERVER_PID=$!
  # Advisory only: some sandboxed shells cannot reach the loopback port even
  # though the simulator can, so a failed probe must not abort the run.
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null -m 2 -u lyra:s3cr3t-webdav-pw \
         -X PROPFIND -H "Depth: 1" "http://127.0.0.1:$PORT/"; then return; fi
    sleep 0.25
  done
  echo "note: could not probe the mock WebDAV server from this shell; continuing" >&2
}

stop_server() { cleanup; SERVER_PID=""; sleep 1; }

# A fresh container per group: the unsigned simulator build has no Keychain
# entitlement, so a WebDAV password never survives a relaunch and a leftover
# source would just be unreachable.
reset_app() {
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
  sleep 4
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  local container
  container="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
  cp -R "$MEDIA/local/Ada Lovelace" "$container/Documents/"
}

run_group() {
  local name="$1"; shift
  local bundle="build/uitest-$name.xcresult"
  rm -rf "$bundle"
  local only=()
  for t in "$@"; do only+=("-only-testing:LyraUITests/LyraUITests/$t"); done
  log "running group: $name"
  xcodebuild test-without-building \
    -project Lyra.xcodeproj -scheme LyraUITests \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath "$DD" "${only[@]}" -resultBundlePath "$bundle" \
    | grep -E "Test Case|XCTAssert|error:" || true
  python3 scripts/uitest/collect-screenshots.py "$bundle" "$EVIDENCE"
  # Each group gets a fresh container, so record what Lyra left in its offline
  # cache before the next reset_app throws the container away.
  local container cache
  container="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
  cache="$container/Library/Application Support/Libraries"
  {
    if [[ -d "$cache" ]]; then
      echo "cached audio files: $(find "$cache" -type f -name '*.flac' | wc -l | tr -d ' ')"
      find "$cache" -type f -name '*.flac' | sed "s|$container|<container>|"
    else
      echo "cached audio files: 0 (directory absent)"
    fi
  } > "build/uitest-$name-offline-cache.txt"
}

[[ -d "$MEDIA" ]] || bash scripts/uitest/make-test-media.sh "$MEDIA"
mkdir -p "$EVIDENCE"

log "booting $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true

log "generating project and building tests"
xcodegen generate
xcodebuild build-for-testing -project Lyra.xcodeproj -scheme LyraUITests \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DD" -quiet

# One access log per group, so the byte accounting for a scenario is not mixed
# in with another scenario's requests.
start_server 0 build/webdav-access-local.jsonl
reset_app
run_group local testLocalLibraryIndexesDroppedFolders testArtistsAndFolderBrowsing

start_server 0 build/webdav-access-index.jsonl
reset_app
run_group webdav testWebDAVLibraryIndexesRemotelyThenDownloadsSelection

start_server 0 build/webdav-access-badcreds.jsonl
reset_app
run_group badcreds testWebDAVRejectsBadCredentials

# A server that answers every GET with the whole file cannot be streamed from.
# Exported rather than prefixed onto the call so the value reaches the server
# process, not just the shell function.
export LYRA_DAV_IGNORE_RANGE=1
start_server 0 build/webdav-access-norange.jsonl
reset_app
run_group norange testStreamingRefusalTellsTheUserToDownloadInstead
unset LYRA_DAV_IGNORE_RANGE

start_server 0 build/webdav-access-preserve.jsonl
reset_app
run_group preserve testRemovingOfflineCopiesAndSourceLeavesUserFilesAlone

# The progress card needs a server slow enough to photograph mid-scan.
start_server 1.0 build/webdav-access-slow.jsonl
reset_app
run_group progress testScanProgressCardIsVisibleWhileIndexing

# Offline-first: download with the server up, then prove it plays with it gone.
start_server 0 build/webdav-access-offline.jsonl
reset_app
run_group offline1 testOfflineFirstStep1KeepAlbumOffline
stop_server
run_group offline2 testOfflineFirstStep2PlaysWithServerGone

log "screenshots in $EVIDENCE"
ls "$EVIDENCE"
