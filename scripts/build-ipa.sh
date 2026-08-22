#!/usr/bin/env bash
#
# Builds an UNSIGNED Lyra.ipa for sideloading with SideStore.
#
# We never sign at build time: SideStore re-signs the app with your own free
# Apple ID certificate when it installs it. Signing here would just be thrown
# away, and it would require a developer account we deliberately do not need.
#
# Output: build/Lyra.ipa
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Lyra"
CONFIGURATION="${CONFIGURATION:-Release}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/Lyra.xcarchive"
IPA_PATH="${BUILD_DIR}/Lyra.ipa"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
command -v xcodegen >/dev/null || die "xcodegen not found — install it with brew install xcodegen."

if [[ -n "${RELEASE_VERSION}" && ! "${RELEASE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  die "RELEASE_VERSION must be a semantic version such as 1.2.0."
fi
if [[ -n "${BUILD_NUMBER}" && ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  die "BUILD_NUMBER must contain digits only."
fi

# The project is generated and gitignored. Always regenerate so a stale local
# project cannot silently package old version or file-list settings.
log "Generating Lyra.xcodeproj"
xcodegen generate

# macOS ships bash 3.2, where "${EMPTY_ARRAY[@]}" is an unbound-variable error
# under `set -u`. The +expansion keeps the no-override run working.
BUILD_SETTINGS=()
[[ -n "${RELEASE_VERSION}" ]] && BUILD_SETTINGS+=("MARKETING_VERSION=${RELEASE_VERSION}")
[[ -n "${BUILD_NUMBER}" ]] && BUILD_SETTINGS+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")

log "Archiving (${CONFIGURATION}, unsigned)"
rm -rf "${ARCHIVE_PATH}"
mkdir -p "${BUILD_DIR}"

BUILD_LOG="${BUILD_DIR}/archive.log"
set +e
xcodebuild archive \
  -project Lyra.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination 'generic/platform=iOS' \
  -archivePath "${ARCHIVE_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"} \
  2>&1 | tee "${BUILD_LOG}" | grep -E '^(\*\*|error:|warning: )'
XCODE_STATUS="${PIPESTATUS[0]}"
set -e

if [[ "${XCODE_STATUS}" -ne 0 ]]; then
  tail -n 100 "${BUILD_LOG}" >&2
  die "xcodebuild archive failed with status ${XCODE_STATUS}."
fi

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Lyra.app"
[[ -d "${APP_PATH}" ]] || die "Archive did not produce ${APP_PATH}"

# An .ipa is just a zip with the app inside a top-level Payload/ directory.
log "Packaging ${IPA_PATH}"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
rm -rf "${PAYLOAD_DIR}" "${IPA_PATH}"
mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"

# -y preserves symlinks inside the bundle; zipping from build/ keeps the
# archive rooted at Payload/ as the format requires.
( cd "${BUILD_DIR}" && zip -qry "Lyra.ipa" "Payload" )
rm -rf "${PAYLOAD_DIR}"

SIZE="$(du -h "${IPA_PATH}" | cut -f1)"
log "Done: ${IPA_PATH} (${SIZE})"
echo
echo "Install it with SideStore:"
echo "  1. AirDrop or copy ${IPA_PATH} to your iPhone."
echo "  2. Open SideStore -> My Apps -> + -> pick Lyra.ipa."
echo "  3. SideStore signs it with your Apple ID. Refresh within 7 days."
