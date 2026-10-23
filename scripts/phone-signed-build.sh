#!/usr/bin/env bash
#
# Build BuddyPhone signed with your own Apple Developer team, for an iPhone connected to this Mac (development
# builds for developers, not TestFlight: scripts/testflight.sh does that). Optionally installs it on the phone.
#
# STATUS: written from Apple's documentation (xcodebuild -help, xcrun devicectl --help) and checked here only
# statically and with fake tools (scripts/test-phone.sh); it has NEVER run against a real device or a real
# developer account. UNVERIFIED until then: that automatic signing creates the App ID, the iCloud container
# link and the development profile for com.sergeyhovakimyan.buddy.phone; the shape of `devicectl list devices` JSON for a
# real, physical iPhone (only a simulator was available, see first_connected_iphone); and
# `devicectl device install app`. Use --dry-run to see the exact commands.
#
# No Team ID or secret is stored in any file: BUDDY_TEAM_ID and the BUDDY_ASC_* variables come from the environment
# only, and everything this script prints (and every tool output it relays) has them masked.

set -euo pipefail

# This script's own folder: symlinks followed, and an exported CDPATH cannot change where `cd` goes.
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "${SCRIPT_PATH}" ]; do
  link_target="$(readlink "${SCRIPT_PATH}")"
  case "${link_target}" in
    /*) SCRIPT_PATH="${link_target}" ;;
    *) SCRIPT_PATH="$(dirname "${SCRIPT_PATH}")/${link_target}" ;;
  esac
done
SCRIPT_DIR="$(unset CDPATH; cd -P "$(dirname "${SCRIPT_PATH}")" >/dev/null && pwd -P)"
REPO_ROOT="$(unset CDPATH; cd -P "${SCRIPT_DIR}/.." >/dev/null && pwd -P)"
APPS_DIR="${REPO_ROOT}/Apps"
PROJECT_YML="${APPS_DIR}/project.yml"
# Relative to Apps/, as xcodebuild resolves it: iCloud container, CloudKit, aps-environment (development).
DEFAULT_ENTITLEMENTS="BuddyPhone/BuddyPhone.cloud.entitlements"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/phone-signed-build.sh [options]

Builds BuddyPhone signed for your iPhone (iCloud + CloudKit + push entitlements, automatic signing with your team)
and verifies the signed app. With --install it also installs it on the phone.

Options:
  --device UDID     The iPhone to build for (as shown by: xcrun devicectl list devices). Default: the first connected
                    physical iPhone reported by devicectl.
  --install         After the build, install the app on the device (xcrun devicectl device install app).
  --register-device Let xcodebuild register the device in the developer portal if it is new there
                    (-allowProvisioningDeviceRegistration). Changes your developer account: off by default.
  --version X.Y.Z   Marketing version (default: MARKETING_VERSION from Apps/project.yml).
  --build N         Build number, CURRENT_PROJECT_VERSION (default: the value in Apps/project.yml).
  --dry-run         Print the exact commands that would run. Nothing is built or installed, no device is contacted,
                    Apple is not contacted.
  --out-dir DIR     Build folder root (default: <repo>/dist); the build goes to DIR/phone-build.
  -h, --help        Show this help.

Environment:
  BUDDY_TEAM_ID          Required. Your Apple Developer Team ID (10 characters). Never written to a file or printed.
  BUDDY_ENTITLEMENTS     Entitlements file relative to Apps/, default BuddyPhone/BuddyPhone.cloud.entitlements.
  BUDDY_ASC_KEY_PATH, BUDDY_ASC_KEY_ID, BUDDY_ASC_ISSUER_ID
                         Optional, all three or none: an App Store Connect API key passed to xcodebuild as
                         -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID. Without it,
                         -allowProvisioningUpdates needs Xcode signed in to the developer account
                         (Xcode > Settings > Accounts).

The iPhone needs iOS 18 or later, Developer Mode on, to trust this Mac, and the same Apple Account signed in to iCloud
as the Mac. After an install, the first launch may need Settings > General > VPN & Device Management > trust your
developer certificate. See docs/cloudkit-setup.md section 8.
USAGE
}

# ---- arguments --------------------------------------------------------------------------------------------------

DEVICE=""
INSTALL=0
REGISTER_DEVICE=0
VERSION=""
BUILD_NUMBER=""
DRY_RUN=0
OUT_DIR="${REPO_ROOT}/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --device)
      [ $# -ge 2 ] || usage_error "--device needs a device identifier (UDID)"
      DEVICE="$2"
      shift 2
      ;;
    --device=*)
      DEVICE="${1#--device=}"
      shift
      ;;
    --install)
      INSTALL=1
      shift
      ;;
    --register-device)
      REGISTER_DEVICE=1
      shift
      ;;
    --version)
      [ $# -ge 2 ] || usage_error "--version needs a value (X.Y.Z)"
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#--version=}"
      shift
      ;;
    --build)
      [ $# -ge 2 ] || usage_error "--build needs a value (a number)"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --build=*)
      BUILD_NUMBER="${1#--build=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --out-dir)
      [ $# -ge 2 ] || usage_error "--out-dir needs a folder"
      OUT_DIR="$2"
      shift 2
      ;;
    --out-dir=*)
      OUT_DIR="${1#--out-dir=}"
      shift
      ;;
    *)
      usage_error "Unknown option: $1"
      ;;
  esac
done

# ---- configuration ----------------------------------------------------------------------------------------------

TEAM_ID=""
require_team_id
check_asc_key optional

ENTITLEMENTS="${BUDDY_ENTITLEMENTS:-${DEFAULT_ENTITLEMENTS}}"
if [ ! -f "${APPS_DIR}/${ENTITLEMENTS}" ]; then
  die "The entitlements file Apps/${ENTITLEMENTS} does not exist (BUDDY_ENTITLEMENTS is relative to Apps/)."
fi

if [ -n "${DEVICE}" ]; then
  printf '%s' "${DEVICE}" | grep -Eq '^[A-Za-z0-9._-]{8,64}$' || die "Invalid --device '${DEVICE}': expected the device identifier (UDID) shown by: xcrun devicectl list devices"
fi
if [ -z "${VERSION}" ]; then
  [ -f "${PROJECT_YML}" ] || die "Apps/project.yml not found at ${PROJECT_YML}"
  VERSION="$(read_marketing_version "${PROJECT_YML}")"
  [ -n "${VERSION}" ] || die "Could not read MARKETING_VERSION from Apps/project.yml; pass --version X.Y.Z"
fi
check_version "${VERSION}"
[ -z "${BUILD_NUMBER}" ] || check_build_number "${BUILD_NUMBER}"

case "${OUT_DIR}" in
  /*) ;;
  *) OUT_DIR="$(pwd)/${OUT_DIR}" ;;
esac
BUILD_DIR="${OUT_DIR}/phone-build"
APP_PATH="${BUILD_DIR}/Build/Products/Debug-iphoneos/BuddyPhone.app"

TMP_ROOT=""
cleanup() {
  local status=$?
  if [ -n "${TMP_ROOT}" ] && [ -d "${TMP_ROOT}" ]; then
    rm -rf "${TMP_ROOT}" || true
  fi
  exit "${status}"
}
trap cleanup EXIT

# ---- preflight --------------------------------------------------------------------------------------------------

preflight() {
  check_build_tools
  # `xcrun --find` is a local lookup, but a dry run makes no xcrun call at all.
  if [ "${DRY_RUN}" -eq 0 ] && { [ "${INSTALL}" -eq 1 ] || [ -z "${DEVICE}" ]; }; then
    xcrun --find devicectl >/dev/null 2>&1 || die "xcrun devicectl not found. It ships with Xcode 15 and later; select a current Xcode with xcode-select."
  fi
  if [ -z "${ASC_KEY_PATH}" ]; then
    info "Note: -allowProvisioningUpdates needs Xcode signed in to the developer account (Xcode > Settings > Accounts) or an App Store Connect API key (BUDDY_ASC_KEY_PATH, BUDDY_ASC_KEY_ID, BUDDY_ASC_ISSUER_ID)."
  fi
}

# Print "<udid> <state>" of the iPhone to build for, from `xcrun devicectl list devices` (JSON, the non-deprecated
# `properties` dictionary). Skips simulators, non-iPhones and "unavailable" devices. Prefers a device whose connection
# state is "connected"; otherwise only a device that is paired (a paired phone reachable over the network, for example);
# an unpaired one is never chosen. UNVERIFIED on a real device: only a simulator entry could be inspected.
first_connected_iphone() {
  local json="${TMP_ROOT}/devices.json" count i udid reality type state pairing fallback=""
  xcrun devicectl list devices --timeout 20 --omit-deprecated-fields-in-json --json-output "${json}" >/dev/null 2>&1 || return 1
  [ -s "${json}" ] || return 1
  count="$(plutil -extract result.devices raw -o - "${json}" 2>/dev/null || echo 0)"
  i=0
  while [ "${i}" -lt "${count}" ]; do
    udid="$(plutil -extract "result.devices.${i}.properties.hardware.udid" raw -o - "${json}" 2>/dev/null || true)"
    [ -n "${udid}" ] || udid="$(plutil -extract "result.devices.${i}.identifier" raw -o - "${json}" 2>/dev/null || true)"
    reality="$(plutil -extract "result.devices.${i}.properties.hardware.reality" raw -o - "${json}" 2>/dev/null || true)"
    type="$(plutil -extract "result.devices.${i}.properties.hardware.deviceType" raw -o - "${json}" 2>/dev/null || true)"
    state="$(plutil -extract "result.devices.${i}.properties.connection.state" raw -o - "${json}" 2>/dev/null || true)"
    pairing="$(plutil -extract "result.devices.${i}.properties.connection.pairingState" raw -o - "${json}" 2>/dev/null || true)"
    i=$((i + 1))
    [ -n "${udid}" ] && [ "${type}" = "iPhone" ] && [ "${reality}" != "simulated" ] && [ "${state}" != "unavailable" ] || continue
    [ "${pairing}" != "unpaired" ] || continue
    if [ "${state}" = "connected" ]; then
      printf '%s connected\n' "${udid}"
      return 0
    fi
    if [ "${pairing}" = "paired" ] && [ -z "${fallback}" ]; then
      fallback="${udid} ${state:-unknown}, paired"
    fi
  done
  [ -n "${fallback}" ] || return 1
  printf '%s\n' "${fallback}"
}

resolve_device() {
  if [ -n "${DEVICE}" ]; then
    return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    info "No --device given: a real run picks the first connected iPhone (xcrun devicectl list devices); this dry run does not look at devices."
    DEVICE="<DEVICE_UDID>"
    return 0
  fi
  info "Looking for a connected iPhone (xcrun devicectl list devices)"
  local found
  found="$(first_connected_iphone || true)"
  [ -n "${found}" ] || die "No connected or paired iPhone found. Connect it with a cable, unlock it, trust this Mac and turn on Developer Mode (Settings > Privacy & Security), then check: xcrun devicectl list devices. Or pass --device <UDID>."
  DEVICE="${found%% *}"
  info "Using device ${DEVICE} (${found#* })"
}

# ---- steps ------------------------------------------------------------------------------------------------------

build_app() {
  local auth=()
  load_auth_args auth
  local args=(
    -project Buddy.xcodeproj -scheme BuddyPhone -configuration Debug
    -destination "platform=iOS,id=${DEVICE}"
    -derivedDataPath "${BUILD_DIR}" -quiet
    "MARKETING_VERSION=${VERSION}"
    "BUDDY_ENTITLEMENTS=${ENTITLEMENTS}"
    "DEVELOPMENT_TEAM=${TEAM_ID}"
    "CODE_SIGN_IDENTITY=Apple Development"
    -allowProvisioningUpdates
  )
  [ -z "${BUILD_NUMBER}" ] || args+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
  [ "${REGISTER_DEVICE}" -eq 0 ] || args+=(-allowProvisioningDeviceRegistration)
  [ "${#auth[@]}" -eq 0 ] || args+=("${auth[@]}")
  args+=(build)

  info "Building BuddyPhone ${VERSION} (Debug, signed for the device)"
  if [ "${DRY_RUN}" -eq 0 ]; then
    rm -rf "${APP_PATH}"
    mkdir -p "${OUT_DIR}"
    # Xcode's logs in the build folder contain the Team ID: keep them private to this user (dist/ is git-ignored).
    mkdir -p "${BUILD_DIR}"
    chmod 700 "${BUILD_DIR}"
  fi
  printf '    (in %s)\n' "$(mask "${APPS_DIR}")"
  (
    cd "${APPS_DIR}"
    run xcodegen generate
    run xcodebuild "${args[@]}"
  )
  [ "${DRY_RUN}" -eq 1 ] || [ -d "${APP_PATH}" ] || die "The build finished but ${APP_PATH} does not exist."
}

team_of() { codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1; }
team_is_ours() { [ "$(team_of "$1")" = "${TEAM_ID}" ]; }
# The app's own CloudKit switch (iOS cannot read its entitlements): the BuddyPhone build phase writes it from the
# entitlements file. Without it the app never turns the phone link on, even when signed correctly.
cloud_flag_on() { [ "$(/usr/libexec/PlistBuddy -c 'Print :BuddyCloudKit' "$1/Info.plist" 2>/dev/null || true)" = "true" ]; }

verify_app() {
  info "Verifying the signed app"
  if [ "${DRY_RUN}" -eq 1 ]; then
    cat <<'PLAN'
    [dry-run] would verify: codesign --verify --deep --strict on the app; an embedded provisioning profile; TeamIdentifier
    equal to BUDDY_TEAM_ID (compared, not printed); the iCloud container, CloudKit service and aps-environment
    entitlements; Info.plist BuddyCloudKit true, version (and build number with --build).
PLAN
    return 0
  fi
  check "codesign --verify --deep --strict on the app" codesign --verify --deep --strict "${APP_PATH}"
  check "the app embeds a provisioning profile" test -f "${APP_PATH}/embedded.mobileprovision"
  check "TeamIdentifier equals BUDDY_TEAM_ID" team_is_ours "${APP_PATH}"
  check "app has the iCloud container entitlement" entitlement_present "${APP_PATH}" "com.apple.developer.icloud-container-identifiers"
  check "app has the CloudKit service entitlement" entitlement_present "${APP_PATH}" "com.apple.developer.icloud-services"
  check "app has an aps-environment entitlement" entitlement_present "${APP_PATH}" "aps-environment"
  check "Info.plist turns CloudKit on (BuddyCloudKit true)" cloud_flag_on "${APP_PATH}"
  local plist_version plist_build
  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Info.plist" 2>/dev/null || true)"
  check "Info.plist version is ${VERSION}" test "${plist_version}" = "${VERSION}"
  if [ -n "${BUILD_NUMBER}" ]; then
    plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Info.plist" 2>/dev/null || true)"
    check "Info.plist build number is ${BUILD_NUMBER}" test "${plist_build}" = "${BUILD_NUMBER}"
  fi
  [ "${check_failed}" -eq 0 ] || die "Verification failed (see the FAIL lines above)."
}

install_app() {
  [ "${INSTALL}" -eq 1 ] || return 0
  info "Installing on the device"
  run xcrun devicectl device install app --device "${DEVICE}" "${APP_PATH}"
}

print_summary() {
  printf '\n'
  if [ "${DRY_RUN}" -eq 1 ]; then
    info "Dry run finished: nothing was built or installed, no device or Apple service was contacted."
    return 0
  fi
  info "Done: ${APP_PATH}"
  if [ "${INSTALL}" -eq 1 ]; then
    cat <<'NOTICE'

Installed. On the iPhone: open Buddy. If iOS says the developer is not trusted, go to Settings > General >
VPN & Device Management and trust your developer certificate. Allow notifications, and make sure the iPhone is
signed in to iCloud with the same Apple Account as the Mac (docs/cloudkit-setup.md section 8).
NOTICE
  else
    printf '\nNot installed (no --install). Install it with: scripts/phone-signed-build.sh --install, or\n  xcrun devicectl device install app --device <UDID> <path above>\n'
  fi
}

# ---- main -------------------------------------------------------------------------------------------------------

if [ "${DRY_RUN}" -eq 1 ]; then
  info "Buddy phone build ${VERSION}: signed development build (dry run)"
else
  info "Buddy phone build ${VERSION}: signed development build"
fi
warn "This script has not been tested against a real device or developer account yet (see the header of the script)."

preflight
if [ "${DRY_RUN}" -eq 0 ]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/buddy-phone.XXXXXX")"
fi
resolve_device
build_app
verify_app
install_app
print_summary
