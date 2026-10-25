#!/usr/bin/env bash
#
# Build the Buddy Mac app in Release and package it as dist/Buddy-<version>.dmg (+ .sha256).
#
# STATUS: the UNSIGNED mode (default) is built and verified on a machine without an Apple Developer account
# (scripts/test-release.sh). The SIGNED mode (Developer ID, hardened runtime, archive + export, notarization) is
# written from Apple's documentation only and is UNTESTED until a real account, certificate and notary profile
# exist (plan Task 17). Use --dry-run to see the exact commands it would run.
#
# No Team ID or secret is stored in any file: BUDDY_TEAM_ID and friends come from the environment only. Everything
# this script prints (and every tool output it relays) has the Team ID, the App Store Connect key path, key id and
# issuer id replaced by <BUDDY_TEAM_ID>, <BUDDY_ASC_KEY_PATH>, <BUDDY_ASC_KEY_ID> and <BUDDY_ASC_ISSUER_ID> (the masking
# helpers are shared with the phone scripts: scripts/lib/common.sh).
#
# Test seam: BUDDY_TEST_IDENTITIES_FILE=<file> makes the certificate lookup read that file (in the format of
# `security find-identity -v -p codesigning`) instead of the keychain. Only scripts/test-release.sh uses it.

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
# Relative to Apps/, as xcodebuild resolves it. The archive is signed for development, so it carries the development
# cloud entitlements (a development profile refuses aps-environment production); the Developer ID export then sets the
# Production container environment (ExportOptions iCloudContainerEnvironment) and the distribution profile's production
# push environment, and verify_signatures checks both on the exported app. Same pattern as testflight.sh.
ARCHIVE_ENTITLEMENTS="BuddyMac/BuddyMac.cloud.entitlements"
VOLUME_NAME="Buddy"

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [options]

Builds BuddyMac (Release) and creates dist/Buddy-<version>.dmg and dist/Buddy-<version>.dmg.sha256.
The dmg holds BuddyMac.app (with buddy-hook embedded) and an "Applications" link. Then it verifies its own output.

Options:
  --version X.Y.Z   Version to build (default: MARKETING_VERSION from Apps/project.yml).
  --build N         Build number, CURRENT_PROJECT_VERSION (default: the value in Apps/project.yml).
  --unsigned        Force the unsigned (ad-hoc) mode even when BUDDY_TEAM_ID is set.
  --skip-notarize   Signed mode only: sign the app and dmg but do not notarize or staple.
  --register-device Signed mode only: let xcodebuild register this Mac in the developer portal if it is new there
                    (-allowProvisioningDeviceRegistration). The development-signed archive needs a profile that
                    lists this Mac; on a fresh team pass it once. Changes your developer account: off by default.
  --dry-run         Print the commands that would run. Nothing is built, written, mounted, and Apple is not contacted.
  --out-dir DIR     Output folder (default: <repo>/dist). The build folder is DIR/build.
  -h, --help        Show this help.

Modes:
  Unsigned (default, when BUDDY_TEAM_ID is unset): ad-hoc signed build, exactly like the default
  Xcode build (no entitlements, no hardened runtime). The dmg is NOT notarized, so macOS Gatekeeper blocks the
  first launch on another Mac. A colleague opens BuddyMac once (macOS blocks it), then goes to
  System Settings > Privacy & Security, clicks "Open Anyway" and confirms. Or runs:
      xattr -dr com.apple.quarantine /Applications/BuddyMac.app

  Signed (BUDDY_TEAM_ID set): xcodebuild archive (development signing, the cloud entitlements, hardened runtime),
  then xcodebuild -exportArchive (method developer-id, iCloud container environment Production), which re-signs with
  Developer ID and the production push environment;
  embedded buddy-hook signed the same way without iCloud entitlements; signed dmg; signature checks; notarization
  (status must be Accepted) and stapling. UNTESTED until a real Apple Developer account exists.

Environment (signed mode):
  BUDDY_TEAM_ID          Apple Team ID (10 characters). Selects signed mode. Never written to a file or printed.
  BUDDY_SIGN_IDENTITY    Signing identity, default "Developer ID Application". Resolved to one certificate (SHA-1)
                         of that team in the keychain; zero or several matches stop the script before building.
                         A name or name prefix only: a SHA-1 hash is NOT supported here (the script resolves the
                         hash itself, from the name, and shows it in the plan).
  BUDDY_NOTARY_PROFILE   notarytool keychain profile (xcrun notarytool store-credentials). Required unless
                         --skip-notarize.
  BUDDY_MAC_PROFILE      Name of the Developer ID provisioning profile for com.sergeyhovakimyan.buddy.mac, default
                         "Buddy Mac Developer ID". The export signs manually with it; it must be installed in
                         ~/Library/Developer/Xcode/UserData/Provisioning Profiles (docs/releasing.md, setup step 2).
  BUDDY_ASC_KEY_PATH, BUDDY_ASC_KEY_ID, BUDDY_ASC_ISSUER_ID
                         Optional, all three or none: an App Store Connect API key passed to xcodebuild as
                         -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID, for CI. Without
                         it, -allowProvisioningUpdates needs Xcode signed in to the developer account
                         (Xcode > Settings > Accounts). The key id is 10 characters, the issuer id a UUID; the key
                         file should be owner-only (chmod 600). All three are masked in every line the script prints.
USAGE
}

# ---- output (masks the Team ID and the App Store Connect key path, key id and issuer id) ------------------------------

# Shared with the phone scripts: add_mask, mask, mask_stream, info, warn, die, usage_error, show_cmd, run, preflight_fail,
# require_team_id, check_asc_key, auth_args. It needs DRY_RUN and usage().
DRY_RUN=0
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

# ---- arguments --------------------------------------------------------------------------------------------------

VERSION=""
BUILD_NUMBER=""
FORCE_UNSIGNED=0
SKIP_NOTARIZE=0
REGISTER_DEVICE=0
OUT_DIR="${REPO_ROOT}/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
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
    --unsigned)
      FORCE_UNSIGNED=1
      shift
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --register-device)
      REGISTER_DEVICE=1
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

# ---- mode, version, paths ---------------------------------------------------------------------------------------

if [ -n "${BUDDY_TEAM_ID:-}" ]; then
  require_team_id # validates the format and registers the Team ID for masking
else
  TEAM_ID=""
fi
# Registered in every mode, so a key given to an unsigned run is never printed either; signed mode validates it in preflight.
add_mask "${BUDDY_ASC_KEY_PATH:-}" "<BUDDY_ASC_KEY_PATH>"
add_mask "${BUDDY_ASC_ISSUER_ID:-}" "<BUDDY_ASC_ISSUER_ID>"
add_mask "${BUDDY_ASC_KEY_ID:-}" "<BUDDY_ASC_KEY_ID>"

SIGN_IDENTITY="${BUDDY_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${BUDDY_NOTARY_PROFILE:-}"
MAC_PROFILE="${BUDDY_MAC_PROFILE:-Buddy Mac Developer ID}"

if [ -n "${TEAM_ID}" ] && [ "${FORCE_UNSIGNED}" -eq 0 ]; then
  MODE="signed"
else
  MODE="unsigned"
fi

if [ "${MODE}" = "unsigned" ] && [ "${SKIP_NOTARIZE}" -eq 1 ]; then
  warn "--skip-notarize has no effect in unsigned mode (nothing is notarized)."
fi
if [ "${MODE}" = "unsigned" ] && [ "${REGISTER_DEVICE}" -eq 1 ]; then
  warn "--register-device has no effect in unsigned mode (nothing is provisioned)."
fi

if [ -z "${VERSION}" ]; then
  [ -f "${PROJECT_YML}" ] || die "Apps/project.yml not found at ${PROJECT_YML}"
  VERSION="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "${PROJECT_YML}" | head -n 1)"
  [ -n "${VERSION}" ] || die "Could not read MARKETING_VERSION from Apps/project.yml; pass --version X.Y.Z"
fi
printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || die "Invalid version '${VERSION}': expected X.Y.Z (digits and dots)."
if [ -n "${BUILD_NUMBER}" ]; then
  printf '%s' "${BUILD_NUMBER}" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "Invalid build number '${BUILD_NUMBER}': expected a number like 7."
fi

case "${OUT_DIR}" in
  /*) ;;
  *) OUT_DIR="$(pwd)/${OUT_DIR}" ;;
esac
BUILD_DIR="${OUT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/Buddy.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
if [ "${MODE}" = "signed" ]; then
  APP_PATH="${EXPORT_DIR}/BuddyMac.app"
else
  APP_PATH="${BUILD_DIR}/Build/Products/Release/BuddyMac.app"
fi
HOOK_PATH="${APP_PATH}/Contents/MacOS/buddy-hook"
DMG_NAME="Buddy-${VERSION}.dmg"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"

TMP_ROOT=""
MOUNT_POINT=""
SIGN_HASH="" # SHA-1 of the one certificate used for the dmg and the export (resolved in preflight)

# ---- helpers ----------------------------------------------------------------------------------------------------

# True when the directory $1 is a mount point (its device differs from its parent's).
is_mounted() {
  [ -d "$1" ] && [ "$(stat -f %d "$1" 2>/dev/null)" != "$(stat -f %d "$(dirname "$1")" 2>/dev/null)" ]
}
# Detach the dmg at $1 (forced as a second try). Succeeds only when it is really gone.
detach_mount() {
  is_mounted "$1" || return 0
  hdiutil detach "$1" -quiet >/dev/null 2>&1 || hdiutil detach "$1" -force -quiet >/dev/null 2>&1 || true
  ! is_mounted "$1"
}

cleanup() {
  local status=$?
  local keep=0
  if [ -n "${MOUNT_POINT}" ]; then
    if ! detach_mount "${MOUNT_POINT}"; then
      keep=1
      warn "could not detach ${MOUNT_POINT}; leaving the temp folder in place (detach it with: hdiutil detach -force '${MOUNT_POINT}')"
    fi
  fi
  # Never rm -rf into a folder that still has a volume mounted in it.
  if [ "${keep}" -eq 0 ] && [ -n "${TMP_ROOT}" ] && [ -d "${TMP_ROOT}" ]; then
    rm -rf "${TMP_ROOT}" || true
  fi
  exit "${status}"
}
trap cleanup EXIT

# ---- preflight --------------------------------------------------------------------------------------------------

read_identities() {
  if [ -n "${BUDDY_TEST_IDENTITIES_FILE:-}" ]; then
    warn "test seam active: BUDDY_TEST_IDENTITIES_FILE is set, so the certificate list is read from that file, not from the keychain. Unset it for a real release."
    cat "${BUDDY_TEST_IDENTITIES_FILE}"
  else
    security find-identity -v -p codesigning 2>/dev/null || true
  fi
}

# Resolve the certificate to one SHA-1 hash: valid identities whose name starts with BUDDY_SIGN_IDENTITY and ends
# with "(<TEAM_ID>)". Zero or several matches are errors; candidates are listed with the Team ID masked.
resolve_certificate() {
  local identities matches count
  identities="$(read_identities)"
  # The same certificate can sit in two keychains (login and a CI keychain) and is listed twice: keep one line per hash.
  matches="$(printf '%s\n' "${identities}" | grep -F -- "\"${SIGN_IDENTITY}" | grep -F -- "(${TEAM_ID})\"" | sort -u -k2,2 || true)"
  count="$(printf '%s' "${matches}" | grep -c . || true)"
  if [ "${count}" -eq 1 ]; then
    SIGN_HASH="$(printf '%s' "${matches}" | awk '{print $2}')"
    return 0
  fi
  local others
  others="$(printf '%s\n' "${identities}" | grep -F -- "\"${SIGN_IDENTITY}" || true)"
  if [ "${count}" -eq 0 ]; then
    preflight_fail "No valid code signing certificate matching '${SIGN_IDENTITY}' for the team in BUDDY_TEAM_ID was found in the keychain. Check with: security find-identity -v -p codesigning. A Developer ID Application certificate is created in the Apple Developer portal and installed in the login keychain.$(
      [ -z "${others}" ] || printf '\nCertificates with that name for other teams (not usable here):\n%s' "${others}"
    )"
  else
    preflight_fail "More than one valid certificate matches '${SIGN_IDENTITY}' for the team in BUDDY_TEAM_ID (ambiguous). Set BUDDY_SIGN_IDENTITY to the full certificate name or remove the stale one from the keychain. Candidates:
${matches}"
  fi
  SIGN_HASH="<SIGN_IDENTITY_SHA1>"
}

preflight() {
  command -v xcodegen >/dev/null 2>&1 || preflight_fail "xcodegen not found. Install it (brew install xcodegen) and retry."
  command -v xcodebuild >/dev/null 2>&1 || preflight_fail "xcodebuild not found. Install Xcode and select it with xcode-select."
  command -v hdiutil >/dev/null 2>&1 || preflight_fail "hdiutil not found (this script needs macOS)."
  command -v codesign >/dev/null 2>&1 || preflight_fail "codesign not found (this script needs macOS)."

  [ "${MODE}" = "signed" ] || return 0

  resolve_certificate
  # All three or none; key id and issuer id format, the key file (exists, readable, not empty, owner-only mode). Masked in all output.
  check_asc_key optional
  if [ -z "${ASC_KEY_PATH}" ]; then
    info "Note: -allowProvisioningUpdates needs Xcode signed in to the developer account (Xcode > Settings > Accounts) or an App Store Connect API key (BUDDY_ASC_KEY_PATH, BUDDY_ASC_KEY_ID, BUDDY_ASC_ISSUER_ID)."
  fi
  if [ "${SKIP_NOTARIZE}" -eq 0 ]; then
    if [ -z "${NOTARY_PROFILE}" ]; then
      preflight_fail "BUDDY_NOTARY_PROFILE is not set. Create a profile once with: xcrun notarytool store-credentials <name>, then export BUDDY_NOTARY_PROFILE=<name>. Or pass --skip-notarize."
    elif [ "${DRY_RUN}" -eq 0 ]; then
      # Contacts Apple, so never under --dry-run.
      if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        die "The notarytool keychain profile '${NOTARY_PROFILE}' is missing or invalid (xcrun notarytool history --keychain-profile failed). Create it with: xcrun notarytool store-credentials."
      fi
    fi
  fi
}

# ---- steps ------------------------------------------------------------------------------------------------------

# The ExportOptions.plist for -exportArchive. Written into the temp folder, never into git.
# Manual signing with a Developer ID provisioning profile (BUDDY_MAC_PROFILE, installed for Xcode). Automatic signing
# fails with an App Store Connect API key: Apple gives API keys no access to cloud-managed Developer ID certificates
# ("Cloud signing permission error", then "No profiles for 'com.sergeyhovakimyan.buddy.mac' were found"). Manual
# signing also honours signingCertificate, so the app and the dmg are signed by the same certificate (SIGN_HASH).
emit_export_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingCertificate</key>
	<string>${SIGN_HASH}</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.sergeyhovakimyan.buddy.mac</key>
		<string>${MAC_PROFILE}</string>
	</dict>
	<key>iCloudContainerEnvironment</key>
	<string>Production</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
}

build_unsigned() {
  local args=(
    -project Buddy.xcodeproj -scheme BuddyMac -configuration Release -destination 'platform=macOS'
    -derivedDataPath "${BUILD_DIR}" -quiet
    "MARKETING_VERSION=${VERSION}"
  )
  [ -z "${BUILD_NUMBER}" ] || args+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
  args+=(build)
  if [ "${DRY_RUN}" -eq 0 ]; then
    rm -rf "${APP_PATH}"
    mkdir -p "${OUT_DIR}"
  fi
  printf '    (in %s)\n' "$(mask "${APPS_DIR}")"
  (
    cd "${APPS_DIR}"
    run xcodegen generate
    run xcodebuild "${args[@]}"
  )
}

build_signed() {
  local auth=()
  load_auth_args auth

  # 1. Archive with automatic (development) signing: hardened runtime and the development cloud entitlements (see
  # ARCHIVE_ENTITLEMENTS). Production is set by the export below and checked on its output.
  local archive_args=(
    -project Buddy.xcodeproj -scheme BuddyMac -configuration Release -destination 'generic/platform=macOS'
    -derivedDataPath "${BUILD_DIR}" -archivePath "${ARCHIVE_PATH}" -quiet
    "MARKETING_VERSION=${VERSION}"
    ENABLE_HARDENED_RUNTIME=YES
    "BUDDY_ENTITLEMENTS=${ARCHIVE_ENTITLEMENTS}"
    "DEVELOPMENT_TEAM=${TEAM_ID}"
    "CODE_SIGN_IDENTITY=Apple Development"
    -allowProvisioningUpdates
  )
  [ -z "${BUILD_NUMBER}" ] || archive_args+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
  [ "${REGISTER_DEVICE}" -eq 0 ] || archive_args+=(-allowProvisioningDeviceRegistration)
  [ "${#auth[@]}" -eq 0 ] || archive_args+=("${auth[@]}")
  archive_args+=(archive)

  # 2. Export for Developer ID: re-signs with the Developer ID certificate and its provisioning profile.
  local plist="${TMP_ROOT:-<tmp>}/ExportOptions.plist"
  local export_args=(
    -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${EXPORT_DIR}"
    -exportOptionsPlist "${plist}" -allowProvisioningUpdates
  )
  [ "${#auth[@]}" -eq 0 ] || export_args+=("${auth[@]}")

  if [ "${DRY_RUN}" -eq 0 ]; then
    rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}"
    mkdir -p "${OUT_DIR}"
  fi
  printf '    (in %s)\n' "$(mask "${APPS_DIR}")"
  (
    cd "${APPS_DIR}"
    run xcodegen generate
    run xcodebuild "${archive_args[@]}"
    printf '    export options plist (generated in a temp folder, not in git):\n'
    if [ "${DRY_RUN}" -eq 1 ]; then
      emit_export_plist | mask_stream | sed 's/^/      | /'
    else
      emit_export_plist >"${plist}"
      mask_stream <"${plist}" | sed 's/^/      | /'
    fi
    run xcodebuild "${export_args[@]}"
  )
}

build_app() {
  info "Building BuddyMac ${VERSION} (Release, ${MODE})"
  if [ "${MODE}" = "signed" ]; then
    build_signed
  else
    build_unsigned
  fi
  [ "${DRY_RUN}" -eq 1 ] || [ -d "${APP_PATH}" ] || die "The build finished but ${APP_PATH} does not exist."
}

make_dmg() {
  info "Creating ${DMG_NAME}"
  local stage="<staging>"
  if [ "${DRY_RUN}" -eq 0 ]; then
    stage="${TMP_ROOT}/stage"
    mkdir -p "${stage}"
    rm -f "${DMG_PATH}"
  fi
  run ditto "${APP_PATH}" "${stage}/BuddyMac.app"
  run ln -s /Applications "${stage}/Applications"
  run hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${stage}" -fs HFS+ -format UDZO -ov "${DMG_PATH}"
  if [ "${MODE}" = "signed" ]; then
    run codesign --force --sign "${SIGN_HASH}" --timestamp "${DMG_PATH}"
  fi
}

notarize_dmg() {
  [ "${MODE}" = "signed" ] || return 0
  if [ "${SKIP_NOTARIZE}" -eq 1 ]; then
    info "Skipping notarization (--skip-notarize): the dmg is signed but not notarized."
    return 0
  fi
  info "Notarizing ${DMG_NAME} (waits for Apple, usually a few minutes)"
  local submit=(xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json)
  if [ "${DRY_RUN}" -eq 1 ]; then
    show_cmd "${submit[@]}"
    printf '    (then: require status Accepted; otherwise print: xcrun notarytool log <id> --keychain-profile %s)\n' "$(mask "${NOTARY_PROFILE}")"
    run xcrun stapler staple "${DMG_PATH}"
    return 0
  fi
  show_cmd "${submit[@]}"
  local json="${TMP_ROOT}/notary-submit.json" err="${TMP_ROOT}/notary-submit.err" status="" id=""
  "${submit[@]}" >"${json}" 2>"${err}" || true
  status="$(plutil -extract status raw -o - "${json}" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "${json}" 2>/dev/null || true)"
  if [ "${status}" != "Accepted" ]; then
    mask_stream <"${err}" >&2 || true
    if [ -n "${id}" ]; then
      info "Notarization status '${status:-unknown}'. Apple's log for submission ${id}:"
      show_cmd xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}"
      xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" 2>&1 | mask_stream >&2 || true
    fi
    die "Notarization was not accepted (status: ${status:-unknown}). The dmg is NOT safe to distribute."
  fi
  info "Notarization accepted (submission ${id})."
  run xcrun stapler staple "${DMG_PATH}"
}

write_checksum() {
  info "Writing ${DMG_NAME}.sha256"
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '    $ (cd %s && shasum -a 256 %s > %s)\n' "$(mask "${OUT_DIR}")" "$(mask "${DMG_NAME}")" "$(mask "${DMG_NAME}.sha256")"
  else
    (cd "${OUT_DIR}" && shasum -a 256 "${DMG_NAME}" >"${DMG_NAME}.sha256")
  fi
}

# ---- verification -----------------------------------------------------------------------------------------------

# check / check_not (and check_failed) come from lib/common.sh.

# `codesign -d` writes to stderr; fold it into stdout.
# grep reads all of its input (no -q): with pipefail, grep -q stops at the first match, codesign then dies of SIGPIPE
# (exit 141) and a signature that is fine fails its check.
codesign_info_has() { codesign -dvv "$1" 2>&1 | grep -F -- "$2" >/dev/null; }
entitlements_of() { codesign -d --entitlements :- "$1" 2>/dev/null; }
entitlements_have() { entitlements_of "$1" | grep -F -- "$2" >/dev/null; }
# True when the entitlement key $2 of $1 has exactly the string value $3. Key-specific: plutil extracts that one key
# (dots in the key escaped, they separate key path components), whatever the layout of the XML codesign prints.
entitlement_value_is() {
  local key="${2//./\\.}"
  [ "$(entitlements_of "$1" | plutil -extract "${key}" raw -o - - 2>/dev/null || true)" = "$3" ]
}
team_of() { codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1; }
team_is_ours() { [ "$(team_of "$1")" = "${TEAM_ID}" ]; }
readlink_is() { [ "$(readlink "$1" 2>/dev/null)" = "$2" ]; }
sha_matches() { (cd "${OUT_DIR}" && shasum -a 256 -c "${DMG_NAME}.sha256"); }

# Bundle helpers (scripts/test-release.sh loads them from here, up to the marker below). Each takes the .app path.
# Mach-O files under $1 (any depth, symlinks not followed), one path per line.
macho_files() {
  local f
  while IFS= read -r -d '' f; do
    case "$(file -b "${f}" 2>/dev/null)" in
      *Mach-O*) printf '%s\n' "${f}" ;;
    esac
  done < <(find "$1" -type f -print0 2>/dev/null)
}
# No Mach-O in Contents/Resources. The one helper, buddy-hook, belongs in Contents/MacOS, where the build signs it as code;
# a second copy in Resources is only sealed as a resource, and Apple's notary service rejects an unsigned Mach-O.
no_macho_in_resources() { [ -z "$(macho_files "$1/Contents/Resources")" ]; }
# At least one Mach-O in the bundle, and every one of them passes codesign --verify --strict.
all_macho_verify() {
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    codesign --verify --strict "${f}" >/dev/null 2>&1 || return 1
  done < <(macho_files "$1")
  [ "${n}" -gt 0 ]
}
# Signed mode: the exported app carries its provisioning profile. The iCloud and push entitlements are restricted: without
# the profile macOS kills the app at launch, although notarization would still accept it.
has_provisioning_profile() { [ -s "$1/Contents/embedded.provisionprofile" ]; }
# end of bundle helpers

# Signature checks, in both modes. In signed mode they run BEFORE notarization, so a bad signature fails locally.
verify_signatures() {
  info "Verifying the signatures"
  if [ "${DRY_RUN}" -eq 1 ]; then
    cat <<'PLAN'
    [dry-run] would verify: codesign --verify --deep --strict on the app; buddy-hook exists, is executable and verifies;
    no Mach-O in Contents/Resources and every Mach-O in the bundle passes codesign --verify --strict;
    CFBundleShortVersionString equals the version (CFBundleVersion equals --build). Signed mode also, before
    notarization: Authority Developer ID Application, a secure timestamp, hardened runtime "(runtime)" and
    TeamIdentifier equal to BUDDY_TEAM_ID on the app and buddy-hook; no get-task-allow; Contents/embedded.provisionprofile
    on the app; the iCloud container,
    CloudKit, container-environment Production and aps-environment production entitlements on the app; none of the
    iCloud keys on buddy-hook; the dmg's signature and authority.
PLAN
    return 0
  fi
  check "codesign --verify --deep --strict on the app" codesign --verify --deep --strict "${APP_PATH}"
  check "embedded buddy-hook exists and is executable" test -x "${HOOK_PATH}"
  check "codesign --verify --strict on buddy-hook" codesign --verify --strict "${HOOK_PATH}"
  check "no Mach-O in Contents/Resources (buddy-hook is only in Contents/MacOS)" no_macho_in_resources "${APP_PATH}"
  if ! no_macho_in_resources "${APP_PATH}"; then
    macho_files "${APP_PATH}/Contents/Resources" | sed 's/^/         stray Mach-O: /' >&2
  fi
  check "every Mach-O in the bundle passes codesign --verify --strict" all_macho_verify "${APP_PATH}"
  local plist_version plist_build
  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
  check "Info.plist version is ${VERSION}" test "${plist_version}" = "${VERSION}"
  if [ -n "${BUILD_NUMBER}" ]; then
    plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
    check "Info.plist build number is ${BUILD_NUMBER}" test "${plist_build}" = "${BUILD_NUMBER}"
  fi

  if [ "${MODE}" = "signed" ]; then
    local target
    for target in "${APP_PATH}" "${HOOK_PATH}"; do
      local name
      name="$(basename "${target}")"
      check "${name}: authority is Developer ID Application" codesign_info_has "${target}" "Authority=Developer ID Application"
      check "${name}: has a secure timestamp" codesign_info_has "${target}" "Timestamp="
      check "${name}: has hardened runtime" codesign_info_has "${target}" "(runtime)"
      check "${name}: TeamIdentifier equals BUDDY_TEAM_ID" team_is_ours "${target}"
      check_not "${name}: has no get-task-allow" entitlements_have "${target}" "com.apple.security.get-task-allow"
    done
    check "app has Contents/embedded.provisionprofile (iCloud and push need it)" has_provisioning_profile "${APP_PATH}"
    check "app has the iCloud container entitlement" entitlements_have "${APP_PATH}" "com.apple.developer.icloud-container-identifiers"
    check "app has the CloudKit service entitlement" entitlements_have "${APP_PATH}" "com.apple.developer.icloud-services"
    check "app has icloud-container-environment Production" entitlement_value_is "${APP_PATH}" "com.apple.developer.icloud-container-environment" "Production"
    check "app has aps-environment production" entitlement_value_is "${APP_PATH}" "com.apple.developer.aps-environment" "production"
    check_not "buddy-hook has no iCloud entitlements" entitlements_have "${HOOK_PATH}" "icloud"
    check "the dmg signature verifies" codesign --verify --strict "${DMG_PATH}"
    check "the dmg authority is Developer ID Application" codesign_info_has "${DMG_PATH}" "Authority=Developer ID Application"
    check "the dmg TeamIdentifier equals BUDDY_TEAM_ID" team_is_ours "${DMG_PATH}"
  fi
  [ "${check_failed}" -eq 0 ] || die "Signature verification failed (see the FAIL lines above); nothing was submitted to Apple."
}

# Checks of the finished dmg (after notarization and stapling in signed mode).
verify_dmg() {
  info "Verifying the dmg"
  if [ "${DRY_RUN}" -eq 1 ]; then
    cat <<'PLAN'
    [dry-run] would verify: the sha256 file matches; the dmg mounts (hdiutil attach -nobrowse -readonly -mountpoint
    <temp dir>, always detached) and holds BuddyMac.app and the Applications link (the app inside verifies too).
    Signed and notarized: stapler validate and spctl on the dmg and the app.
PLAN
    return 0
  fi
  check "sha256 file matches the dmg" sha_matches

  # Mount the dmg read-only at a private mount point; the EXIT trap always detaches it.
  local mnt="${TMP_ROOT}/mnt"
  mkdir -p "${mnt}"
  if hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${mnt}" "${DMG_PATH}" >/dev/null 2>&1; then
    MOUNT_POINT="${mnt}"
    check "dmg mounts and contains BuddyMac.app" test -d "${mnt}/BuddyMac.app"
    check "dmg contains an Applications link to /Applications" readlink_is "${mnt}/Applications" /Applications
    check "the app inside the dmg verifies (codesign --deep --strict)" codesign --verify --deep --strict "${mnt}/BuddyMac.app"
    check "buddy-hook inside the dmg is executable" test -x "${mnt}/BuddyMac.app/Contents/MacOS/buddy-hook"
    if detach_mount "${mnt}"; then
      MOUNT_POINT=""
    fi
  else
    printf '    FAIL the dmg does not mount\n' >&2
    check_failed=1
  fi

  if [ "${MODE}" = "signed" ] && [ "${SKIP_NOTARIZE}" -eq 0 ]; then
    check "stapler validate on the dmg" xcrun stapler validate "${DMG_PATH}"
    check "spctl accepts the dmg (notarized)" spctl --assess --type open --context context:primary-signature "${DMG_PATH}"
    check "spctl accepts the app" spctl --assess --type execute "${APP_PATH}"
  elif [ "${MODE}" = "signed" ]; then
    info "spctl checks skipped (--skip-notarize): Gatekeeper rejects an unnotarized app by design."
  fi

  [ "${check_failed}" -eq 0 ] || die "Verification failed (see the FAIL lines above)."
}

print_summary() {
  printf '\n'
  if [ "${DRY_RUN}" -eq 1 ]; then
    info "Dry run finished: nothing was built, written, mounted or sent to Apple."
    return 0
  fi
  info "Done: ${DMG_PATH}"
  info "      ${SHA_PATH}"
  if [ "${MODE}" = "unsigned" ]; then
    cat <<NOTICE

NOTICE: this dmg is UNSIGNED and NOT NOTARIZED (ad-hoc signature only). macOS Gatekeeper blocks the first
launch on another Mac. Tell the colleague to
  - drag Buddy to Applications and open BuddyMac once (macOS blocks it), then go to
    System Settings > Privacy & Security, click "Open Anyway" and confirm, or
  - run: xattr -dr com.apple.quarantine /Applications/BuddyMac.app
This build has no iCloud entitlements: the phone link is off (Mac-only). For a notarized build with the phone
link, set BUDDY_TEAM_ID (see scripts/README.md).
NOTICE
  elif [ "${SKIP_NOTARIZE}" -eq 1 ]; then
    printf '\nNOTICE: signed but NOT notarized (--skip-notarize). Gatekeeper still blocks it on other Macs.\n'
  fi
}

# ---- main -------------------------------------------------------------------------------------------------------

if [ "${DRY_RUN}" -eq 1 ]; then
  info "Buddy release ${VERSION}: ${MODE} mode (dry run)"
else
  info "Buddy release ${VERSION}: ${MODE} mode"
fi
if [ "${MODE}" = "signed" ]; then
  warn "Signed mode has not been tested end to end yet (it was written without an Apple Developer account)."
fi

preflight
if [ "${DRY_RUN}" -eq 0 ]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/buddy-release.XXXXXX")"
fi
build_app
make_dmg
verify_signatures
notarize_dmg
write_checksum
verify_dmg
print_summary
