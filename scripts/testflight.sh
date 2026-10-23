#!/usr/bin/env bash
#
# Archive BuddyPhone, export it for App Store Connect, verify the exported .ipa and upload it to TestFlight
# (internal testers only).
#
# STATUS: written from Apple's documentation (xcodebuild -help and xcrun altool --help of this Xcode) and checked only
# statically and with fake tools (scripts/test-phone.sh). It has NEVER run against a real developer account: there is
# none yet (plan Task 17). Use --dry-run to see the exact commands, and --export-only to stop before the upload.
#
# Flow: archive -> check the archive -> `xcodebuild -exportArchive` (ExportOptions destination `export`, method
# app-store-connect, distribution signing) into a local .ipa -> verify that .ipa (production push, Production CloudKit
# environment, no get-task-allow, team, version, build number) -> upload THAT verified .ipa with
# `xcrun altool --upload-app -f <ipa> --api-key ... --api-issuer ... --p8-file-path ...` (documented in `xcrun altool
# --help` of this Xcode). So what is uploaded is exactly what was verified. Fallback if altool's flags turn out wrong
# on the first real run: `--upload-with xcodebuild` re-runs the export with destination `upload` (documented in
# `xcodebuild -help`), which signs and uploads in one step. That second export signs again, so only the FIRST export is
# verified, not the bytes that are uploaded (the script says so at run time).
#
# Push and CloudKit environments: BuddyPhone.cloud.entitlements asks for aps-environment "development" and has no
# container-environment key; the archive is signed with a development profile. The App Store export re-signs with the
# distribution (App Store) profile: Xcode then writes aps-environment "production", drops get-task-allow, and the CloudKit
# container environment is Production for distribution signing (the export option iCloudContainerEnvironment=Production
# says so explicitly). So no phone release entitlements file is needed, and verify_ipa checks the result on the real
# output. (release.sh does the same for the Mac: development values at archive, Production at the Developer ID export.)
#
# STILL UNVERIFIED (needs the account): that automatic signing with the API key creates the cloud-managed
# distribution certificate and App Store profile (use an Admin key); that the exported entitlements are what the
# paragraph above says (verify_ipa fails loudly if not); that altool accepts these flags; that the App Store Connect app
# record for com.sergeyhovakimyan.buddy.phone exists (create it once in App Store Connect > Apps, after the bundle ID exists:
# run --export-only once first); that the upload is accepted (icon, privacy, export compliance:
# ITSAppUsesNonExemptEncryption is already false); and that testFlightInternalTestingOnly is still honoured when the
# verified .ipa is uploaded with altool (the option used to apply at upload time; now it only sits in the export of a
# local .ipa and altool has no matching flag): after the first upload, App Store Connect must show the build as
# Internal Only, otherwise use --upload-with xcodebuild.
#
# Order on a fresh developer account: the archive is signed with a development profile, which Apple only creates when the
# team has at least one registered device ("Your team has no devices from which to generate a provisioning profile").
# Run `scripts/phone-signed-build.sh --register-device` with your iPhone connected first (or add the device in the
# developer portal), then --export-only, then create the app record, then the real upload.
#
# No Team ID or secret is stored in any file: BUDDY_TEAM_ID and the BUDDY_ASC_* variables come from the environment
# only, and everything this script prints (and every tool output it relays) has them masked. The ExportOptions.plist is
# generated into a mode 0700 temp folder and deleted on exit, never into git. Xcode itself copies the Team ID into
# the build folder (dist/testflight-build: archive Info.plist, export logs, ExportOptions.plist, DistributionSummary.plist);
# that folder is git-ignored and made private to your user (chmod 700), delete it when you are done.

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
DEFAULT_ENTITLEMENTS="BuddyPhone/BuddyPhone.cloud.entitlements"
BUNDLE_ID="com.sergeyhovakimyan.buddy.phone"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/testflight.sh [options]

Archives BuddyPhone (Release, automatic signing with your team), exports it for App Store Connect (distribution
signing) into a local .ipa, verifies that .ipa and uploads it to TestFlight. Meant for internal testers only: the export
sets testFlightInternalTestingOnly, but whether that survives an altool upload has not been checked yet. After the first
upload, check that App Store Connect shows the build as Internal Only (docs/releasing.md, "What has never been run",
item 6); if it does not, upload again with --upload-with xcodebuild.

Options:
  --build N         Build number, CURRENT_PROJECT_VERSION. Default: the current UTC time as YYYYMMDDHHMM, which only
                    ever grows. App Store Connect refuses a build number that is not higher than the last upload of
                    the same version.
  --version X.Y.Z   Marketing version (default: MARKETING_VERSION from Apps/project.yml).
  --export-only     Archive, export the signed .ipa into the output folder and verify it, but do not upload. The API
                    key is then optional. Recommended before the first real upload.
  --upload-with T   How the verified .ipa is uploaded: altool (default, xcrun altool --upload-app) or xcodebuild
                    (the export is run again with destination upload; fallback if altool's flags do not work).
                    With xcodebuild the second export signs again, so the uploaded file is NOT the verified .ipa.
  --dry-run         Print the exact commands that would run (secrets and the Team ID masked). Nothing is built,
                    written or uploaded, and Apple is not contacted.
  --out-dir DIR     Output folder (default: <repo>/dist); archive and export go to DIR/testflight-build.
  -h, --help        Show this help.

Environment:
  BUDDY_TEAM_ID          Required. Your Apple Developer Team ID (10 characters). Never written to a file or printed.
  BUDDY_ASC_KEY_PATH     Required for the upload (all three): the App Store Connect API key file (AuthKey_<id>.p8),
  BUDDY_ASC_KEY_ID       its key id and the issuer id, from App Store Connect > Users and Access > Integrations.
  BUDDY_ASC_ISSUER_ID    Use an Admin key: other roles often cannot create the cloud-managed distribution certificate.
  BUDDY_ENTITLEMENTS     Entitlements file relative to Apps/, default BuddyPhone/BuddyPhone.cloud.entitlements.

Before the first upload, in this order:
  1. Accept the current agreements (App Store Connect > Business / the developer portal).
  2. Register your iPhone: scripts/phone-signed-build.sh --register-device (a team with no device cannot archive).
  3. Run scripts/testflight.sh --export-only (creates the App ID and profiles and checks the .ipa).
  4. Create the app record for com.sergeyhovakimyan.buddy.phone in App Store Connect > Apps (it needs the App ID from step 3).
  5. Deploy the CloudKit schema to Production (docs/cloudkit-setup.md section 5) and add the internal testers.
After the upload, processing takes a few minutes before the build shows in TestFlight.
USAGE
}

# ---- arguments --------------------------------------------------------------------------------------------------

VERSION=""
BUILD_NUMBER=""
EXPORT_ONLY=0
UPLOAD_WITH="altool"
DRY_RUN=0
OUT_DIR="${REPO_ROOT}/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
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
    --version)
      [ $# -ge 2 ] || usage_error "--version needs a value (X.Y.Z)"
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#--version=}"
      shift
      ;;
    --export-only)
      EXPORT_ONLY=1
      shift
      ;;
    --upload-with)
      [ $# -ge 2 ] || usage_error "--upload-with needs altool or xcodebuild"
      UPLOAD_WITH="$2"
      shift 2
      ;;
    --upload-with=*)
      UPLOAD_WITH="${1#--upload-with=}"
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

case "${UPLOAD_WITH}" in
  altool | xcodebuild) ;;
  *) usage_error "--upload-with must be altool or xcodebuild (got '${UPLOAD_WITH}')" ;;
esac

TEAM_ID=""
require_team_id
if [ "${EXPORT_ONLY}" -eq 1 ]; then
  check_asc_key optional
else
  check_asc_key required
fi

ENTITLEMENTS="${BUDDY_ENTITLEMENTS:-${DEFAULT_ENTITLEMENTS}}"
[ -f "${APPS_DIR}/${ENTITLEMENTS}" ] || die "The entitlements file Apps/${ENTITLEMENTS} does not exist (BUDDY_ENTITLEMENTS is relative to Apps/)."

if [ -z "${VERSION}" ]; then
  [ -f "${PROJECT_YML}" ] || die "Apps/project.yml not found at ${PROJECT_YML}"
  VERSION="$(read_marketing_version "${PROJECT_YML}")"
  [ -n "${VERSION}" ] || die "Could not read MARKETING_VERSION from Apps/project.yml; pass --version X.Y.Z"
fi
check_version "${VERSION}"
BUILD_FROM_TIME=0
if [ -z "${BUILD_NUMBER}" ]; then
  BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
  BUILD_FROM_TIME=1
fi
check_build_number "${BUILD_NUMBER}"

case "${OUT_DIR}" in
  /*) ;;
  *) OUT_DIR="$(pwd)/${OUT_DIR}" ;;
esac
BUILD_DIR="${OUT_DIR}/testflight-build"
ARCHIVE_PATH="${BUILD_DIR}/BuddyPhone.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
IPA_PATH="${EXPORT_DIR}/BuddyPhone.ipa"
EXPORT_UPLOAD_DIR="${BUILD_DIR}/export-upload"
ARCHIVE_APP="${ARCHIVE_PATH}/Products/Applications/BuddyPhone.app"

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
  if [ -z "${ASC_KEY_PATH}" ]; then
    info "Note: without an API key, -allowProvisioningUpdates needs Xcode signed in to the developer account (Xcode > Settings > Accounts)."
  fi
}

# ---- steps ------------------------------------------------------------------------------------------------------

# The ExportOptions.plist for -exportArchive. $1 is the destination: upload or export.
emit_export_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$1</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>iCloudContainerEnvironment</key>
	<string>Production</string>
	<key>testFlightInternalTestingOnly</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
}

archive_app() {
  local auth=()
  load_auth_args auth
  local args=(
    -project Buddy.xcodeproj -scheme BuddyPhone -configuration Release -destination 'generic/platform=iOS'
    -derivedDataPath "${BUILD_DIR}/derived" -archivePath "${ARCHIVE_PATH}" -quiet
    "MARKETING_VERSION=${VERSION}"
    "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"
    "BUDDY_ENTITLEMENTS=${ENTITLEMENTS}"
    "DEVELOPMENT_TEAM=${TEAM_ID}"
    "CODE_SIGN_IDENTITY=Apple Development"
    -allowProvisioningUpdates
  )
  [ "${#auth[@]}" -eq 0 ] || args+=("${auth[@]}")
  args+=(archive)

  info "Archiving BuddyPhone ${VERSION} (${BUILD_NUMBER})"
  if [ "${DRY_RUN}" -eq 0 ]; then
    rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${EXPORT_UPLOAD_DIR}"
    mkdir -p "${BUILD_DIR}"
    chmod 700 "${BUILD_DIR}"
  fi
  printf '    (in %s)\n' "$(mask "${APPS_DIR}")"
  (
    cd "${APPS_DIR}" &&
      run xcodegen generate &&
      run xcodebuild "${args[@]}"
  ) || die "The archive failed (see the output above). Common causes: a team with no registered device (\"Your team has no devices from which to generate a provisioning profile\": run scripts/phone-signed-build.sh --register-device with your iPhone connected, or add the device in the developer portal); the Apple Developer Program License Agreement is not accepted yet (App Store Connect / the developer portal); the API key is missing a role (use an Admin key) or Xcode is not signed in to the account."
  [ "${DRY_RUN}" -eq 1 ] || [ -d "${ARCHIVE_APP}" ] || die "The archive finished but ${ARCHIVE_APP} does not exist."
}

team_of() { codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1; }
team_is_ours() { [ "$(team_of "$1")" = "${TEAM_ID}" ]; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || true; }
plist_is() { [ "$(plist_value "$1" "$2")" = "$3" ]; }
not_true() { [ "$(entitlement_raw "$1" "$2")" != "true" ]; }
# On iOS, Xcode writes the icon name only inside CFBundleIcons:CFBundlePrimaryIcon (checked against a real build);
# a top-level CFBundleIconName is the macOS layout and is NOT accepted here.
ICON_KEY="CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName"

# What can be checked on the archive before anything is exported or uploaded.
verify_archive() {
  info "Verifying the archive"
  if [ "${DRY_RUN}" -eq 1 ]; then
    cat <<'PLAN'
    [dry-run] would verify on the archived app: bundle id com.sergeyhovakimyan.buddy.phone, version and build number, the app icon
    (CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconName AppIcon, and Assets.car), codesign --verify --deep --strict,
    TeamIdentifier equal to BUDDY_TEAM_ID (compared, not printed), the iCloud container and CloudKit entitlements, and
    Info.plist BuddyCloudKit true (the app's own CloudKit switch).
PLAN
    return 0
  fi
  check "bundle id is ${BUNDLE_ID}" plist_is "${ARCHIVE_APP}" CFBundleIdentifier "${BUNDLE_ID}"
  check "version is ${VERSION}" plist_is "${ARCHIVE_APP}" CFBundleShortVersionString "${VERSION}"
  check "build number is ${BUILD_NUMBER}" plist_is "${ARCHIVE_APP}" CFBundleVersion "${BUILD_NUMBER}"
  check "the app icon is declared (CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconName AppIcon)" plist_is "${ARCHIVE_APP}" "${ICON_KEY}" AppIcon
  check "the asset catalog is in the app (Assets.car)" test -f "${ARCHIVE_APP}/Assets.car"
  check "codesign --verify --deep --strict on the app" codesign --verify --deep --strict "${ARCHIVE_APP}"
  check "TeamIdentifier equals BUDDY_TEAM_ID" team_is_ours "${ARCHIVE_APP}"
  check "app has the iCloud container entitlement" entitlement_present "${ARCHIVE_APP}" "com.apple.developer.icloud-container-identifiers"
  check "app has the CloudKit service entitlement" entitlement_present "${ARCHIVE_APP}" "com.apple.developer.icloud-services"
  check "Info.plist turns CloudKit on (BuddyCloudKit true)" plist_is "${ARCHIVE_APP}" BuddyCloudKit true
  [ "${check_failed}" -eq 0 ] || die "Archive verification failed (see the FAIL lines above); nothing was exported or uploaded."
}

# Run the export. $1 is the destination (export: a local .ipa; upload: sign and upload in one step), $2 the export folder.
export_app() {
  local destination="$1" folder="$2"
  local auth=()
  load_auth_args auth
  local plist="${TMP_ROOT:-<tmp>}/ExportOptions-${destination}.plist"
  local args=(
    -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${folder}"
    -exportOptionsPlist "${plist}" -allowProvisioningUpdates
  )
  [ "${#auth[@]}" -eq 0 ] || args+=("${auth[@]}")

  printf '    export options plist, destination %s (generated in a temp folder, not in git):\n' "${destination}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    emit_export_plist "${destination}" | mask_stream | sed 's/^/      | /'
  else
    emit_export_plist "${destination}" >"${plist}"
    mask_stream <"${plist}" | sed 's/^/      | /'
  fi
  printf '    (in %s)\n' "$(mask "${APPS_DIR}")"
  (
    cd "${APPS_DIR}" &&
      run xcodebuild "${args[@]}"
  ) || die "$(failure_hints "The export failed")"
}

failure_hints() {
  printf '%s (see the output above). Things to check: (1) there is no App Store Connect app record for %s ("No suitable application records were found"): create it in App Store Connect > Apps once the App ID exists (an earlier run of this script with --export-only creates the App ID); (2) the Apple Developer Program License Agreement or the App Store Connect agreements are not accepted; (3) the API key cannot create distribution certificates and profiles ("Cloud signing permission error"): use an Admin key; (4) the build number %s is not higher than the last upload of version %s: pass a higher --build; (5) your team has no registered device: scripts/phone-signed-build.sh --register-device.' "$1" "${BUNDLE_ID}" "${BUILD_NUMBER}" "${VERSION}"
}

# Checks of the exported .ipa. Always run, so what gets uploaded is exactly what was verified.
verify_ipa() {
  info "Verifying the exported .ipa"
  if [ "${DRY_RUN}" -eq 1 ]; then
    cat <<'PLAN'
    [dry-run] would verify on the exported .ipa (unpacked into a temp folder): it exists; codesign --verify --deep
    --strict; TeamIdentifier equal to BUDDY_TEAM_ID; aps-environment production; icloud-container-environment
    Production; no get-task-allow; the iCloud container and CloudKit entitlements; version and build number.
PLAN
    return 0
  fi
  check "the .ipa exists" test -f "${IPA_PATH}"
  [ "${check_failed}" -eq 0 ] || die "Export verification failed (see the FAIL lines above): ${IPA_PATH} was not produced."
  local unpacked="${TMP_ROOT}/ipa" app
  mkdir -p "${unpacked}"
  ditto -x -k "${IPA_PATH}" "${unpacked}" || die "Could not unpack ${IPA_PATH} to check it (ditto -x -k failed); nothing was uploaded."
  app="${unpacked}/Payload/BuddyPhone.app"
  check "the .ipa holds Payload/BuddyPhone.app" test -d "${app}"
  check "codesign --verify --deep --strict on the exported app" codesign --verify --deep --strict "${app}"
  check "TeamIdentifier equals BUDDY_TEAM_ID" team_is_ours "${app}"
  check "version is ${VERSION}" plist_is "${app}" CFBundleShortVersionString "${VERSION}"
  check "build number is ${BUILD_NUMBER}" plist_is "${app}" CFBundleVersion "${BUILD_NUMBER}"
  check "aps-environment is production" entitlement_value_is "${app}" "aps-environment" "production"
  check "icloud-container-environment is Production" entitlement_value_is "${app}" "com.apple.developer.icloud-container-environment" "Production"
  check "app has the iCloud container entitlement" entitlement_present "${app}" "com.apple.developer.icloud-container-identifiers"
  check "app has the CloudKit service entitlement" entitlement_present "${app}" "com.apple.developer.icloud-services"
  check "app is not debuggable (get-task-allow is not true)" not_true "${app}" "get-task-allow"
  [ "${check_failed}" -eq 0 ] || die "Export verification failed (see the FAIL lines above); the .ipa was not uploaded."
}

upload_app() {
  [ "${EXPORT_ONLY}" -eq 0 ] || return 0
  info "Uploading to App Store Connect (${UPLOAD_WITH}; waits for the upload)"
  if [ "${UPLOAD_WITH}" = "xcodebuild" ]; then
    warn "--upload-with xcodebuild signs the package again: what is uploaded is a fresh export, not the .ipa that was just verified."
    export_app upload "${EXPORT_UPLOAD_DIR}"
    return 0
  fi
  (
    run xcrun altool --upload-app -f "${IPA_PATH}" --api-key "${ASC_KEY_ID}" --api-issuer "${ASC_ISSUER_ID}" --p8-file-path "${ASC_KEY_PATH}"
  ) || die "$(failure_hints "The upload failed")"
}

print_summary() {
  printf '\n'
  if [ "${DRY_RUN}" -eq 1 ]; then
    info "Dry run finished: nothing was built, written or uploaded, and Apple was not contacted."
    return 0
  fi
  if [ "${EXPORT_ONLY}" -eq 1 ]; then
    info "Done: ${IPA_PATH} (signed and verified, NOT uploaded)"
    printf 'To upload, run this script again without --export-only (it archives and exports again; pass --build N\nto reuse a build number, it must be higher than every build already uploaded for this version).\n'
    return 0
  fi
  info "Uploaded BuddyPhone ${VERSION} (${BUILD_NUMBER}) to App Store Connect."
  cat <<'NOTICE'

App Store Connect now processes the build (a few minutes). Then open App Store Connect > your app > TestFlight, answer
the export compliance question if it is asked (the app uses no non-exempt encryption) and check that the build shows as
Internal Only (never verified for an altool upload; if it does not, add no testers and upload again with
--upload-with xcodebuild). Then add the internal testers. They install it from the TestFlight app on the iPhone.
NOTICE
}

# ---- main -------------------------------------------------------------------------------------------------------

mode="upload to TestFlight (${UPLOAD_WITH})"
[ "${EXPORT_ONLY}" -eq 0 ] || mode="export only, no upload"
if [ "${DRY_RUN}" -eq 1 ]; then
  info "Buddy TestFlight ${VERSION} (${BUILD_NUMBER}): ${mode} (dry run)"
else
  info "Buddy TestFlight ${VERSION} (${BUILD_NUMBER}): ${mode}"
fi
[ "${BUILD_FROM_TIME}" -eq 0 ] || info "Build number from the UTC time (use --build N to choose one)."
warn "This script has not been tested against a real developer account or App Store Connect yet (see the header of the script)."

preflight
if [ "${DRY_RUN}" -eq 0 ]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/buddy-testflight.XXXXXX")"
fi
archive_app
verify_archive
info "Exporting the signed .ipa (distribution signing, destination export)"
export_app export "${EXPORT_DIR}"
verify_ipa
upload_app
print_summary
