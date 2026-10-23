#!/usr/bin/env bash
#
# Tests for scripts/phone-signed-build.sh, scripts/testflight.sh, scripts/lib/common.sh and the placeholder app icons.
#
# Safe by design and needs neither a device nor an Apple account: every tool the scripts call (xcodegen, xcodebuild,
# xcrun/devicectl) is replaced by a FAKE on PATH that only records its arguments (and, for build and archive, makes a
# tiny ad-hoc signed stand-in app, never launched). Nothing contacts Apple, nothing is installed to a device or to
# /Applications, no real signing identity or Team ID is used (ZZTEST0000 is made up), the real Application Support
# folder and Claude settings are not touched (HOME points to a temp folder), everything is written to a temp folder.
#
# Usage: scripts/test-phone.sh

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
PHONE="${SCRIPT_DIR}/phone-signed-build.sh"
FLIGHT="${SCRIPT_DIR}/testflight.sh"
COMMON="${SCRIPT_DIR}/lib/common.sh"

case "${1:-}" in
  "") ;;
  *)
    echo "usage: $0" >&2
    exit 2
    ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/buddy-phone-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/home" "${WORK}/fakebin"

FAKE_TEAM="ZZTEST0000"
FAKE_KEY_ID="ZZKEY12345"
FAKE_ISSUER="12345678-aaaa-bbbb-cccc-123456789abc"
KEY="${WORK}/AuthKey_${FAKE_KEY_ID}.p8"
printf 'fake-not-a-real-key' >"${KEY}"
chmod 600 "${KEY}"

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  printf 'ok   %s\n' "$1"
}
fail() {
  failed=$((failed + 1))
  printf 'FAIL %s\n' "$1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /' >&2
}
assert() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi
}
contains() { grep -Fq -- "$2" <<<"$1"; }
assert_has() {
  if contains "$2" "$3"; then pass "$1"; else fail "$1 (missing: $3)" "$2"; fi
}
assert_lacks() {
  if contains "$2" "$3"; then fail "$1 (unexpected: $3)" "$2"; else pass "$1"; fi
}
assert_rc() { # assert_rc "<name>" <expected> (uses $RC and $OUT)
  if [ "${RC}" -eq "$2" ]; then pass "$1"; else fail "$1 (rc=${RC}, wanted $2)" "${OUT}"; fi
}
assert_rc_nonzero() {
  if [ "${RC}" -ne 0 ]; then pass "$1"; else fail "$1 (rc=0)" "${OUT}"; fi
}

# ---- fake tools --------------------------------------------------------------------------------------------------

export FAKE_LOG="${WORK}/calls.log"
FAKE_DEVICES="${WORK}/devices.json"

cat >"${WORK}/fakebin/xcodegen" <<'FAKE'
#!/bin/bash
echo "xcodegen $*" >>"${FAKE_LOG}"
FAKE
# The Info.plist of the fake apps is a copy of the one a REAL Release iphoneos build of BuddyPhone produced
# (scripts/testdata/BuddyPhone.Info.plist): the icon name sits in CFBundleIcons > CFBundlePrimaryIcon, there is no
# top-level CFBundleIconName. Never invent a layout here.
export FAKE_INFO_PLIST="${SCRIPT_DIR}/testdata/BuddyPhone.Info.plist"

# codesign shim: the real codesign (ad-hoc signing and verification really run), but `-dvv` reports a TeamIdentifier,
# which an ad-hoc signature cannot carry. For a path under /Payload/ (the unpacked .ipa) it reports FAKE_IPA_TEAM.
cat >"${WORK}/fakebin/codesign" <<'FAKE'
#!/bin/bash
dvv=0
last=""
for a in "$@"; do
  [ "$a" != "-dvv" ] || dvv=1
  last="$a"
done
if [ "${dvv}" -eq 1 ]; then
  team="${FAKE_TEAM_ID}"
  case "${last}" in */Payload/*) team="${FAKE_IPA_TEAM:-${FAKE_TEAM_ID}}" ;; esac
  /usr/bin/codesign "$@" 2>&1 | sed "s/^TeamIdentifier=.*/TeamIdentifier=${team}/" >&2
  exit "${PIPESTATUS[0]}"
fi
exec /usr/bin/codesign "$@"
FAKE
cat >"${WORK}/fakebin/xcodegen" <<'FAKE'
#!/bin/bash
echo "xcodegen $*" >>"${FAKE_LOG}"
FAKE
cat >"${WORK}/fakebin/xcodebuild" <<'FAKE'
#!/bin/bash
# Fake xcodebuild: records the call; build/archive make an ad-hoc signed stand-in app (real Info.plist layout, real
# entitlements from BUDDY_ENTITLEMENTS); -exportArchive makes a real zipped .ipa (Payload/BuddyPhone.app, re-signed ad hoc
# with the entitlements of FAKE_IPA_VARIANT). FAKE_FAIL=archive|export|upload makes that step fail. Like the real
# "Record the CloudKit entitlement" phase it writes BuddyCloudKit true; FAKE_NO_CLOUD_FLAG=1 leaves it out.
echo "xcodebuild $*" >>"${FAKE_LOG}"
mode=build
dd="" ap="" ex="" ent="" ver="" bld="" opts=""
while [ $# -gt 0 ]; do
  case "$1" in
    -derivedDataPath) dd="$2"; shift ;;
    -archivePath) ap="$2"; shift ;;
    -exportPath) ex="$2"; shift ;;
    -exportOptionsPlist) opts="$2"; shift ;;
    -exportArchive) mode=export ;;
    archive) mode=archive ;;
    MARKETING_VERSION=*) ver="${1#*=}" ;;
    CURRENT_PROJECT_VERSION=*) bld="${1#*=}" ;;
    BUDDY_ENTITLEMENTS=*) ent="${1#*=}" ;;
  esac
  shift
done
set_info() { /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1/Info.plist"; }
sign() { # sign <app> [entitlements-plist]
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    codesign --force --sign - --entitlements "$2" "$1" >/dev/null 2>&1
  else
    codesign --force --sign - "$1" >/dev/null 2>&1
  fi
}
make_app() {
  local dir="$1"
  mkdir -p "${dir}"
  cp /usr/bin/true "${dir}/BuddyPhone"
  cp "${FAKE_INFO_PLIST}" "${dir}/Info.plist"
  [ -z "${ver}" ] || set_info "${dir}" CFBundleShortVersionString "${ver}"
  [ -z "${bld}" ] || set_info "${dir}" CFBundleVersion "${bld}"
  if [ "${FAKE_NO_ICON:-0}" = "1" ]; then /usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" "${dir}/Info.plist"; fi
  if [ "${FAKE_TOPLEVEL_ICON:-0}" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" -c "Add :CFBundleIconName string AppIcon" "${dir}/Info.plist"
  fi
  [ "${FAKE_NO_CLOUD_FLAG:-0}" = "1" ] || /usr/libexec/PlistBuddy -c "Add :BuddyCloudKit bool true" "${dir}/Info.plist"
  : >"${dir}/Assets.car"
  : >"${dir}/embedded.mobileprovision"
  sign "${dir}" "${ent}"
}
make_ipa() {
  local stage app ents="$ex/../ipa-entitlements.plist" variant="${FAKE_IPA_VARIANT:-good}"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/fake-ipa.XXXXXX")"
  mkdir -p "${stage}/Payload" "${ex}"
  app="${stage}/Payload/BuddyPhone.app"
  ditto "${ap}/Products/Applications/BuddyPhone.app" "${app}"
  local aps=production env='<key>com.apple.developer.icloud-container-environment</key><string>Production</string>' gta='<key>get-task-allow</key><false/>'
  case "${variant}" in
    aps-dev) aps=development ;;
    no-container-env) env="" ;;
    get-task-allow) gta='<key>get-task-allow</key><true/>' ;;
    wrong-build) set_info "${app}" CFBundleVersion 999 ;;
  esac
  cat >"${ents}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>aps-environment</key><string>${aps}</string>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.sergeyhovakimyan.buddy</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
${env}
${gta}
</dict></plist>
PLIST
  sign "${app}" "${ents}"
  rm -f "${ents}"
  if [ "${variant}" != "no-ipa" ]; then ditto -c -k "${stage}" "${ex}/BuddyPhone.ipa"; fi
  rm -rf "${stage}"
}
dest=""
[ -z "${opts}" ] || dest="$(plutil -extract destination raw -o - "${opts}" 2>/dev/null || true)"
[ "${mode}" != "export" ] || echo "export-destination=${dest}" >>"${FAKE_LOG}"
if [ "${FAKE_FAIL:-}" = "${mode}" ] || { [ "${FAKE_FAIL:-}" = "upload" ] && [ "${dest}" = "upload" ]; }; then
  echo "error: fake ${mode} failure for team ${FAKE_TEAM_ID}" >&2
  exit 65
fi
case "${mode}" in
  build) make_app "${dd}/Build/Products/Debug-iphoneos/BuddyPhone.app" ;;
  archive) make_app "${ap}/Products/Applications/BuddyPhone.app" ;;
  export)
    if [ "${dest}" = "upload" ]; then mkdir -p "${ex}"; else make_ipa; fi
    ;;
esac
FAKE
cat >"${WORK}/fakebin/xcrun" <<'FAKE'
#!/bin/bash
# Fake xcrun: devicectl (list devices, install app) and altool (--upload-app). Everything else is recorded and fails.
echo "xcrun $*" >>"${FAKE_LOG}"
case "$1" in
  --find) exit 0 ;;
  altool)
    if [ "${FAKE_ALTOOL_RC:-0}" != "0" ]; then
      echo "fake altool failure for key ${FAKE_KEY_ID_SEEN:-}" >&2
      exit "${FAKE_ALTOOL_RC}"
    fi
    exit 0
    ;;
  devicectl)
    case "$2 $3" in
      "list devices")
        out=""
        while [ $# -gt 0 ]; do
          [ "$1" != "--json-output" ] || out="$2"
          shift
        done
        [ -z "${out}" ] || cp "${FAKE_DEVICES}" "${out}"
        exit 0
        ;;
      "device install") exit 0 ;;
    esac
    ;;
esac
exit 1
FAKE
chmod +x "${WORK}/fakebin/"*

# devicectl JSON in the shape of this Xcode (`properties`, as `devicectl list devices --json-output` writes it).
write_devices() { # write_devices <file> <entry>... where entry = udid:type:reality:state:pairingState
  local f="$1" e first=1
  shift
  {
    printf '{"result":{"devices":['
    for e in "$@"; do
      IFS=: read -r udid type reality state pairing <<<"${e}"
      [ "${first}" -eq 1 ] || printf ','
      first=0
      printf '{"identifier":"%s","properties":{"connection":{"state":"%s","pairingState":"%s"},"hardware":{"udid":"%s","deviceType":"%s","reality":"%s"}}}' "${udid}" "${state}" "${pairing}" "${udid}" "${type}" "${reality}"
    done
    printf ']}}'
  } >"${f}"
}
write_devices "${FAKE_DEVICES}" \
  "SIMULATOR-0000-0000:iPhone:simulated:disconnected:paired" \
  "UNAVAILABLE-1111-1111:iPhone:physical:unavailable:paired" \
  "IPAD-2222-2222-2222:iPad:physical:connected:paired" \
  "UNPAIRED-3333-3333:iPhone:physical:disconnected:unpaired" \
  "PHONE-3333-3333-3333:iPhone:physical:disconnected:paired" \
  "PHONE-4444-4444-4444:iPhone:physical:connected:paired"

# Run a script with a CLEAN environment (no BUDDY_* from the caller, HOME in the temp folder), the fakes first on PATH.
# run_case [VAR=value ...] -- <command> [args...]   -> $OUT (stdout+stderr), $RC
OUT=""
RC=0
run_case() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"${FAKE_LOG}"
  set +e
  if [ "${#envs[@]}" -gt 0 ]; then
    OUT="$(env -i PATH="${WORK}/fakebin:${PATH}" HOME="${WORK}/home" TMPDIR="${WORK}" FAKE_LOG="${FAKE_LOG}" FAKE_DEVICES="${FAKE_DEVICES}" FAKE_TEAM_ID="${FAKE_TEAM}" FAKE_INFO_PLIST="${FAKE_INFO_PLIST}" "${envs[@]}" "$@" 2>&1)"
  else
    OUT="$(env -i PATH="${WORK}/fakebin:${PATH}" HOME="${WORK}/home" TMPDIR="${WORK}" FAKE_LOG="${FAKE_LOG}" FAKE_DEVICES="${FAKE_DEVICES}" FAKE_TEAM_ID="${FAKE_TEAM}" FAKE_INFO_PLIST="${FAKE_INFO_PLIST}" "$@" 2>&1)"
  fi
  RC=$?
  set -e
}
calls() { cat "${FAKE_LOG}"; }
no_calls() { [ ! -s "${FAKE_LOG}" ]; }
no_tmp_left() { ! ls "${WORK}" | grep -q '^buddy-\(phone\|testflight\)\.'; }

ASC=("BUDDY_ASC_KEY_PATH=${KEY}" "BUDDY_ASC_KEY_ID=${FAKE_KEY_ID}" "BUDDY_ASC_ISSUER_ID=${FAKE_ISSUER}")
TEAM="BUDDY_TEAM_ID=${FAKE_TEAM}"

# ---- static ------------------------------------------------------------------------------------------------------

for f in "${PHONE}" "${FLIGHT}"; do
  assert "$(basename "${f}") is executable" test -x "${f}"
done
for f in "${PHONE}" "${FLIGHT}" "${COMMON}" "${BASH_SOURCE[0]}"; do
  assert "bash -n $(basename "${f}")" bash -n "${f}"
done
assert "the scripts use set -euo pipefail" bash -c 'grep -q "^set -euo pipefail" "$1" && grep -q "^set -euo pipefail" "$2"' _ "${PHONE}" "${FLIGHT}"
assert "no bash 4 features (declare -A, mapfile, case conversion)" bash -c '! grep -E "declare -A|mapfile|readarray|\$\{[a-zA-Z_]+(,,|\^\^)\}" "$@"' _ "${PHONE}" "${FLIGHT}" "${COMMON}"
if command -v shellcheck >/dev/null 2>&1; then
  assert "shellcheck phone-signed-build.sh" shellcheck -x "${PHONE}"
  assert "shellcheck testflight.sh" shellcheck -x "${FLIGHT}"
else
  printf 'skip shellcheck (not installed)\n'
fi

# ---- phone-signed-build.sh: help and argument errors ---------------------------------------------------------------

run_case -- "${PHONE}" --help
assert_rc "phone --help exits 0" 0
assert_has "phone --help shows usage" "${OUT}" "Usage: scripts/phone-signed-build.sh"
assert_has "phone --help documents BUDDY_TEAM_ID" "${OUT}" "BUDDY_TEAM_ID"
assert_has "phone --help documents --device" "${OUT}" "--device UDID"
assert_has "phone --help documents --install" "${OUT}" "--install"
assert_has "phone --help documents --dry-run" "${OUT}" "--dry-run"
assert_has "phone --help documents the API key variables" "${OUT}" "BUDDY_ASC_KEY_PATH"
assert_has "phone --help documents BUDDY_ENTITLEMENTS" "${OUT}" "BUDDY_ENTITLEMENTS"
assert "phone --help calls no tool" no_calls

run_case "${TEAM}" -- "${PHONE}" --frobnicate
assert_rc "phone: unknown flag exits 2" 2
assert_has "phone: unknown flag is named" "${OUT}" "Unknown option: --frobnicate"
assert_has "phone: unknown flag prints usage" "${OUT}" "Usage: scripts/phone-signed-build.sh"
run_case "${TEAM}" -- "${PHONE}" --device
assert_rc "phone: --device without a value exits 2" 2
run_case "${TEAM}" -- "${PHONE}" --version
assert_rc "phone: --version without a value exits 2" 2
run_case "${TEAM}" -- "${PHONE}" --build
assert_rc "phone: --build without a value exits 2" 2
run_case "${TEAM}" -- "${PHONE}" --out-dir
assert_rc "phone: --out-dir without a value exits 2" 2

# ---- phone-signed-build.sh: missing or bad environment -------------------------------------------------------------

run_case -- "${PHONE}"
assert_rc "phone: missing BUDDY_TEAM_ID exits 1" 1
assert_has "phone: missing BUDDY_TEAM_ID message" "${OUT}" "BUDDY_TEAM_ID is not set"
assert "phone: missing BUDDY_TEAM_ID calls no tool" no_calls
run_case -- "${PHONE}" --dry-run
assert_rc "phone: missing BUDDY_TEAM_ID fails even under --dry-run" 1
run_case BUDDY_TEAM_ID=short -- "${PHONE}" --dry-run
assert_rc "phone: malformed BUDDY_TEAM_ID exits 1" 1
assert_has "phone: malformed BUDDY_TEAM_ID message" "${OUT}" "10 character"
run_case "${TEAM}" -- "${PHONE}" --version 1.x --dry-run
assert_rc "phone: invalid version exits 1" 1
assert_has "phone: invalid version message" "${OUT}" "Invalid version"
run_case "${TEAM}" -- "${PHONE}" --build x7 --dry-run
assert_rc "phone: invalid build number exits 1" 1
assert_has "phone: invalid build number message" "${OUT}" "Invalid build number"
run_case "${TEAM}" -- "${PHONE}" --device 'a b;rm' --dry-run
assert_rc "phone: an invalid --device exits 1" 1
assert_has "phone: an invalid --device message" "${OUT}" "Invalid --device"
run_case "${TEAM}" BUDDY_ENTITLEMENTS=BuddyPhone/does-not-exist.entitlements -- "${PHONE}" --dry-run
assert_rc "phone: a missing entitlements file exits 1" 1
assert_has "phone: a missing entitlements file message" "${OUT}" "does not exist"

# the API key: all three or none, formats, and the key file (real runs fail before any tool runs)
run_case "${TEAM}" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" -- "${PHONE}" --device DEVICE-0000-0001
assert_rc "phone: a partial BUDDY_ASC_* set exits 1" 1
assert_has "phone: a partial BUDDY_ASC_* set message" "${OUT}" "all of BUDDY_ASC_KEY_PATH"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${KEY}" BUDDY_ASC_KEY_ID=bad BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --device DEVICE-0000-0001
assert_rc "phone: a malformed key id exits 1" 1
assert_has "phone: a malformed key id message" "${OUT}" "BUDDY_ASC_KEY_ID must be"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${KEY}" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID=not-a-uuid -- "${PHONE}" --device DEVICE-0000-0001
assert_rc "phone: a malformed issuer id exits 1" 1
assert_has "phone: a malformed issuer id message" "${OUT}" "BUDDY_ASC_ISSUER_ID must be"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/nope.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --device DEVICE-0000-0001
assert_rc "phone: a missing key file exits 1" 1
assert_has "phone: a missing key file message" "${OUT}" "does not exist"
assert "phone: a missing key file stops before any tool runs" no_calls
assert_lacks "phone: a missing key file message masks the key path" "${OUT}" "${WORK}/nope.p8"
mkdir -p "${WORK}/keydir"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/keydir" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --device DEVICE-0000-0001
assert_rc "phone: a key path that is a folder exits 1" 1
assert_has "phone: a key path that is a folder message" "${OUT}" "not a file"
: >"${WORK}/empty.p8"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/empty.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --device DEVICE-0000-0001
assert_rc "phone: an empty key file exits 1" 1
assert_has "phone: an empty key file message" "${OUT}" "empty file"
printf 'x' >"${WORK}/locked.p8"
chmod 000 "${WORK}/locked.p8"
if [ ! -r "${WORK}/locked.p8" ]; then
  run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/locked.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --device DEVICE-0000-0001
  assert_rc "phone: an unreadable key file exits 1" 1
  assert_has "phone: an unreadable key file message" "${OUT}" "not readable"
else
  printf 'skip unreadable key file test (running with file permissions ignored)\n'
fi
printf 'x' >"${WORK}/open.p8"
chmod 644 "${WORK}/open.p8"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/open.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --dry-run --device DEVICE-0000-0001
assert_rc "phone: a world-readable key file only warns" 0
assert_has "phone: a world-readable key file warns" "${OUT}" "accessible to other users"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/nope.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --dry-run --device DEVICE-0000-0001
assert_rc "phone: a missing key file under --dry-run is a warning" 0
assert_has "phone: --dry-run says it would fail" "${OUT}" "(dry-run, would fail)"

# ---- phone-signed-build.sh: dry run --------------------------------------------------------------------------------

run_case "${TEAM}" "${ASC[@]}" -- "${PHONE}" --dry-run --build 7 --version 1.2.3 --out-dir "${WORK}/phone-dry"
assert_rc "phone --dry-run exits 0" 0
assert "phone --dry-run calls no tool (xcodegen, xcodebuild, xcrun)" no_calls
assert "phone --dry-run creates nothing" test ! -e "${WORK}/phone-dry"
assert "phone --dry-run leaves no temp folder" no_tmp_left
assert_has "phone dry-run: xcodegen" "${OUT}" "xcodegen generate"
assert_has "phone dry-run: scheme and Debug configuration" "${OUT}" "-scheme BuddyPhone -configuration Debug"
assert_has "phone dry-run: no device given is shown as a placeholder" "${OUT}" "platform=iOS,id=<DEVICE_UDID>"
assert_has "phone dry-run: cloud entitlements by default" "${OUT}" "BUDDY_ENTITLEMENTS=BuddyPhone/BuddyPhone.cloud.entitlements"
assert_has "phone dry-run: team passed (masked)" "${OUT}" "DEVELOPMENT_TEAM=<BUDDY_TEAM_ID>"
assert_has "phone dry-run: Apple Development identity" "${OUT}" "CODE_SIGN_IDENTITY=Apple Development"
assert_has "phone dry-run: provisioning updates" "${OUT}" "-allowProvisioningUpdates"
assert_has "phone dry-run: version" "${OUT}" "MARKETING_VERSION=1.2.3"
assert_has "phone dry-run: build number" "${OUT}" "CURRENT_PROJECT_VERSION=7"
assert_has "phone dry-run: key path masked" "${OUT}" "-authenticationKeyPath '<BUDDY_ASC_KEY_PATH>'"
assert_has "phone dry-run: key id masked" "${OUT}" "-authenticationKeyID '<BUDDY_ASC_KEY_ID>'"
assert_has "phone dry-run: issuer masked" "${OUT}" "-authenticationKeyIssuerID '<BUDDY_ASC_ISSUER_ID>'"
assert_lacks "phone dry-run never prints the team id" "${OUT}" "${FAKE_TEAM}"
assert_lacks "phone dry-run never prints the key id" "${OUT}" "${FAKE_KEY_ID}"
assert_lacks "phone dry-run never prints the issuer id" "${OUT}" "${FAKE_ISSUER}"
assert_lacks "phone dry-run never prints the key path" "${OUT}" "${KEY}"
assert_lacks "phone dry-run without --install has no install command" "${OUT}" "device install"
assert_lacks "phone dry-run does not register devices by default" "${OUT}" "allowProvisioningDeviceRegistration"
assert_has "phone dry-run: says it is untested" "${OUT}" "not been tested"
assert_has "phone dry-run: ends with the dry-run notice" "${OUT}" "Dry run finished"

run_case "${TEAM}" -- "${PHONE}" --dry-run --device 00008110-001234560E01801E --install --register-device
assert_rc "phone --dry-run --device --install exits 0" 0
assert_has "phone dry-run: the given device is the destination" "${OUT}" "platform=iOS,id=00008110-001234560E01801E"
assert_has "phone dry-run: --install uses devicectl" "${OUT}" "xcrun devicectl device install app --device 00008110-001234560E01801E"
assert_has "phone dry-run: --register-device" "${OUT}" "-allowProvisioningDeviceRegistration"
assert_lacks "phone dry-run without an API key has no authentication flags" "${OUT}" "-authenticationKeyPath"
assert_has "phone dry-run without an API key notes the Xcode account" "${OUT}" "Xcode signed in"
assert "phone --dry-run --install calls no tool" no_calls
lower="$(tr 'A-Z' 'a-z' <<<"${FAKE_TEAM}")"
run_case "${TEAM}" -- "${PHONE}" --dry-run --device "dev-${lower}-device"
assert_has "phone: the Team ID is masked in any case" "${OUT}" "dev-<BUDDY_TEAM_ID>-device"
assert_lacks "phone: a lower-case Team ID is not printed" "${OUT}" "${lower}"

# ---- phone-signed-build.sh: real runs with the fake tools ------------------------------------------------------------

# A good run: the fake build makes an ad-hoc signed stand-in app (real Info.plist layout, the real cloud entitlements);
# the codesign shim reports the fake team, so every check really runs and passes.
run_case "${TEAM}" -- "${PHONE}" --out-dir "${WORK}/phone-real" --build 9
assert_rc "phone: a real run with fakes passes every check" 0
assert_has "phone real: finds the connected physical iPhone, skipping simulators, iPads, unavailable and unpaired ones" "${OUT}" "Using device PHONE-4444-4444-4444 (connected)"
assert_has "phone real: builds for that device" "$(calls)" "platform=iOS,id=PHONE-4444-4444-4444"
assert_has "phone real: the build ran" "$(calls)" "xcodebuild -project Buddy.xcodeproj -scheme BuddyPhone"
assert_has "phone real: verification ran on the app (codesign)" "${OUT}" "ok   codesign --verify --deep --strict on the app"
assert_has "phone real: checks the provisioning profile" "${OUT}" "ok   the app embeds a provisioning profile"
assert_has "phone real: the Team check passes (codesign shim reports a team)" "${OUT}" "ok   TeamIdentifier equals BUDDY_TEAM_ID"
assert_has "phone real: checks the iCloud container entitlement" "${OUT}" "ok   app has the iCloud container entitlement"
assert_has "phone real: checks the CloudKit entitlement" "${OUT}" "ok   app has the CloudKit service entitlement"
assert_has "phone real: checks aps-environment" "${OUT}" "ok   app has an aps-environment entitlement"
assert_has "phone real: checks the CloudKit switch in Info.plist" "${OUT}" "ok   Info.plist turns CloudKit on (BuddyCloudKit true)"
assert_has "phone real: checks the version" "${OUT}" "ok   Info.plist version is"
assert_has "phone real: checks the build number" "${OUT}" "ok   Info.plist build number is 9"
assert_lacks "phone real: no failed check" "${OUT}" "FAIL"
assert_has "phone real: ends with Done" "${OUT}" "==> Done:"
assert_has "phone real: says it was not installed without --install" "${OUT}" "Not installed (no --install)"
assert_lacks "phone real: nothing is installed without --install" "$(calls)" "device install"
assert "phone real: removes its temp folder" no_tmp_left
assert_lacks "phone real: never prints the team id" "${OUT}" "${FAKE_TEAM}"
assert "phone real: the build folder is owner-only (700)" bash -c '[ "$(stat -f %Lp "$1")" = "700" ]' _ "${WORK}/phone-real/phone-build"

# A build whose Info.plist lacks the CloudKit switch would never turn the phone link on: verification fails, nothing installs.
run_case "${TEAM}" FAKE_NO_CLOUD_FLAG=1 -- "${PHONE}" --out-dir "${WORK}/phone-noflag" --install
assert_rc_nonzero "phone real: an app without BuddyCloudKit fails verification"
assert_has "phone real: the CloudKit switch check fails" "${OUT}" "FAIL Info.plist turns CloudKit on (BuddyCloudKit true)"
assert_lacks "phone real: nothing is installed after a failed verification" "$(calls)" "device install"

run_case "${TEAM}" -- "${PHONE}" --out-dir "${WORK}/phone-real-i" --device PHONE-9999-9999-9999 --install
assert_rc "phone: a good run with --device and --install exits 0" 0
assert_lacks "phone: --device skips the device search" "$(calls)" "list devices"
assert_has "phone: --device is the destination" "$(calls)" "platform=iOS,id=PHONE-9999-9999-9999"
assert_has "phone: the install runs on that device (fake devicectl)" "$(calls)" "xcrun devicectl device install app --device PHONE-9999-9999-9999"
assert_has "phone: the install comes after the verification" "${OUT}" "==> Installing"

# negatives
run_case "${TEAM}" FAKE_TEAM_ID=ZZOTHER000 -- "${PHONE}" --out-dir "${WORK}/phone-neg1" --device PHONE-9999-9999-9999 --install
assert_rc_nonzero "phone real: the wrong team fails the run"
assert_has "phone real: the Team check fails" "${OUT}" "FAIL TeamIdentifier equals BUDDY_TEAM_ID"
assert_has "phone real: verification failure is fatal" "${OUT}" "Verification failed"
assert_lacks "phone real: nothing is installed after a failed verification" "$(calls)" "device install"
assert_lacks "phone real: the wrong team id is not printed either" "${OUT}" "ZZOTHER000"
run_case "${TEAM}" FAKE_FAIL=build -- "${PHONE}" --out-dir "${WORK}/phone-neg2" --device PHONE-9999-9999-9999 --install
assert_rc_nonzero "phone real: a failed build fails the run"
assert_lacks "phone real: a failed build installs nothing" "$(calls)" "device install"
assert_lacks "phone real: tool output is masked (the fake prints the team id)" "${OUT}" "${FAKE_TEAM}"
assert "phone real: a failed build leaves no temp folder" no_tmp_left

# devicectl device choice: connected first, otherwise paired only, never unpaired
write_devices "${WORK}/no-devices.json" "SIMULATOR-0000-0000:iPhone:simulated:disconnected:paired" "IPAD-2222-2222-2222:iPad:physical:connected:paired" "UNPAIRED-3333-3333:iPhone:physical:disconnected:unpaired" "UNPAIRED-4444-4444:iPhone:physical:connected:unpaired"
run_case "${TEAM}" FAKE_DEVICES="${WORK}/no-devices.json" -- "${PHONE}" --out-dir "${WORK}/phone-real3"
assert_rc "phone: no connected or paired iPhone exits 1" 1
assert_has "phone: no connected or paired iPhone message" "${OUT}" "No connected or paired iPhone found"
assert_has "phone: no connected iPhone points at devicectl and --device" "${OUT}" "xcrun devicectl list devices"
assert_lacks "phone: no device means no build" "$(calls)" "xcodebuild"
assert_lacks "phone: an unpaired iPhone is never chosen" "${OUT}" "UNPAIRED-"
write_devices "${WORK}/one-offline.json" "UNPAIRED-3333-3333:iPhone:physical:disconnected:unpaired" "PHONE-5555-5555-5555:iPhone:physical:disconnected:paired"
run_case "${TEAM}" FAKE_DEVICES="${WORK}/one-offline.json" -- "${PHONE}" --out-dir "${WORK}/phone-real4"
assert_has "phone: falls back to a paired, not connected iPhone when none is connected" "${OUT}" "Using device PHONE-5555-5555-5555 (disconnected, paired)"
write_devices "${WORK}/two.json" "PHONE-6666-6666-6666:iPhone:physical:disconnected:paired" "UNPAIRED-7777-7777:iPhone:physical:connected:unpaired" "PHONE-8888-8888-8888:iPhone:physical:connected:paired"
run_case "${TEAM}" FAKE_DEVICES="${WORK}/two.json" -- "${PHONE}" --out-dir "${WORK}/phone-real5"
assert_has "phone: a connected paired iPhone beats a paired offline one and an unpaired connected one" "${OUT}" "Using device PHONE-8888-8888-8888 (connected)"

# ---- testflight.sh: help and argument errors -----------------------------------------------------------------------

run_case -- "${FLIGHT}" --help
assert_rc "testflight --help exits 0" 0
assert_has "testflight --help shows usage" "${OUT}" "Usage: scripts/testflight.sh"
assert_has "testflight --help documents --build" "${OUT}" "--build N"
assert_has "testflight --help documents --export-only" "${OUT}" "--export-only"
assert_has "testflight --help documents --dry-run" "${OUT}" "--dry-run"
assert_has "testflight --help documents BUDDY_TEAM_ID" "${OUT}" "BUDDY_TEAM_ID"
assert_has "testflight --help documents the API key variables" "${OUT}" "BUDDY_ASC_ISSUER_ID"
assert "testflight --help calls no tool" no_calls
run_case "${TEAM}" -- "${FLIGHT}" --frobnicate
assert_rc "testflight: unknown flag exits 2" 2
assert_has "testflight: unknown flag is named" "${OUT}" "Unknown option: --frobnicate"
run_case "${TEAM}" -- "${FLIGHT}" --build
assert_rc "testflight: --build without a value exits 2" 2

# ---- testflight.sh: missing or bad environment ---------------------------------------------------------------------

run_case "${ASC[@]}" -- "${FLIGHT}" --dry-run
assert_rc "testflight: missing BUDDY_TEAM_ID exits 1" 1
assert_has "testflight: missing BUDDY_TEAM_ID message" "${OUT}" "BUDDY_TEAM_ID is not set"
run_case BUDDY_TEAM_ID=nope "${ASC[@]}" -- "${FLIGHT}" --dry-run
assert_rc "testflight: malformed BUDDY_TEAM_ID exits 1" 1
run_case "${TEAM}" -- "${FLIGHT}" --dry-run
assert_rc "testflight: missing API key exits 1 (even under --dry-run)" 1
assert_has "testflight: missing API key message" "${OUT}" "App Store Connect API key is not set"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${KEY}" -- "${FLIGHT}" --dry-run
assert_rc "testflight: a partial API key exits 1" 1
assert_has "testflight: a partial API key message" "${OUT}" "all of BUDDY_ASC_KEY_PATH"
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/nope.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${FLIGHT}" --build 5
assert_rc "testflight: a missing key file exits 1" 1
assert_has "testflight: a missing key file message" "${OUT}" "does not exist"
assert "testflight: a missing key file stops before any tool runs" no_calls
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/empty.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${FLIGHT}" --build 5
assert_rc "testflight: an empty key file exits 1" 1
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/keydir" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${FLIGHT}" --build 5
assert_rc "testflight: a key path that is a folder exits 1" 1
run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${KEY}" BUDDY_ASC_KEY_ID=bad BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${FLIGHT}" --build 5
assert_rc "testflight: a malformed key id exits 1" 1
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --build 5x
assert_rc "testflight: an invalid build number exits 1" 1
assert_has "testflight: an invalid build number message" "${OUT}" "Invalid build number"
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --version 1
assert_rc "testflight: an invalid version exits 1" 1
run_case "${TEAM}" "${ASC[@]}" BUDDY_ENTITLEMENTS=nope.entitlements -- "${FLIGHT}" --dry-run
assert_rc "testflight: a missing entitlements file exits 1" 1
run_case "${TEAM}" -- "${FLIGHT}" --dry-run --export-only
assert_rc "testflight: --export-only does not need the API key" 0

# ---- testflight.sh: dry run ----------------------------------------------------------------------------------------

yml_version="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "${REPO_ROOT}/Apps/project.yml" | head -n 1)"
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --dry-run --build 77 --out-dir "${WORK}/tf-dry"
assert_rc "testflight --dry-run exits 0" 0
assert "testflight --dry-run calls no tool (xcodegen, xcodebuild, xcrun)" no_calls
assert "testflight --dry-run creates nothing" test ! -e "${WORK}/tf-dry"
assert "testflight --dry-run leaves no temp folder" no_tmp_left
assert_has "testflight dry-run: default version from project.yml" "${OUT}" "MARKETING_VERSION=${yml_version}"
assert_has "testflight dry-run: archive action" "${OUT}" "-scheme BuddyPhone -configuration Release -destination generic/platform=iOS"
assert_has "testflight dry-run: archives" "${OUT}" " archive"
assert_has "testflight dry-run: archive path" "${OUT}" "-archivePath ${WORK}/tf-dry/testflight-build/BuddyPhone.xcarchive"
assert_has "testflight dry-run: build number" "${OUT}" "CURRENT_PROJECT_VERSION=77"
assert_has "testflight dry-run: cloud entitlements" "${OUT}" "BUDDY_ENTITLEMENTS=BuddyPhone/BuddyPhone.cloud.entitlements"
assert_has "testflight dry-run: team passed (masked)" "${OUT}" "DEVELOPMENT_TEAM=<BUDDY_TEAM_ID>"
assert_has "testflight dry-run: exportArchive" "${OUT}" "-exportArchive -archivePath"
assert_has "testflight dry-run: export options plist path" "${OUT}" "-exportOptionsPlist"
assert_has "testflight dry-run: provisioning updates" "${OUT}" "-allowProvisioningUpdates"
assert_has "testflight dry-run: API key flags masked" "${OUT}" "-authenticationKeyPath '<BUDDY_ASC_KEY_PATH>' -authenticationKeyID '<BUDDY_ASC_KEY_ID>' -authenticationKeyIssuerID '<BUDDY_ASC_ISSUER_ID>'"
assert_has "testflight dry-run: plist method app-store-connect" "${OUT}" "<string>app-store-connect</string>"
assert_has "testflight dry-run: the export is a local .ipa (plist destination export)" "${OUT}" "<key>destination</key>"$'\n'"      | 	<string>export</string>"
assert_lacks "testflight dry-run: the default does not sign-and-upload in one step (destination upload)" "${OUT}" "<string>upload</string>"
assert_has "testflight dry-run: verifies the exported .ipa before the upload" "${OUT}" "would verify on the exported .ipa"
assert_has "testflight dry-run: uploads the verified .ipa with altool" "${OUT}" "xcrun altool --upload-app -f ${WORK}/tf-dry/testflight-build/export/BuddyPhone.ipa --api-key '<BUDDY_ASC_KEY_ID>' --api-issuer '<BUDDY_ASC_ISSUER_ID>' --p8-file-path '<BUDDY_ASC_KEY_PATH>'"
assert "testflight dry-run: the .ipa is verified before the upload (order)" bash -c 'o="$1"; a="${o%%would verify on the exported*}"; b="${o#*would verify on the exported}"; case "$a" in *"xcrun altool"*) exit 1;; esac; case "$b" in *"xcrun altool"*) exit 0;; esac; exit 1' _ "${OUT}"
assert_has "testflight dry-run: archive check names the nested iOS icon key" "${OUT}" "CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconName AppIcon"
assert_has "testflight dry-run: plist team (masked)" "${OUT}" "<string><BUDDY_TEAM_ID></string>"
assert_has "testflight dry-run: plist automatic signing" "${OUT}" "<key>signingStyle</key>"$'\n'"      | 	<string>automatic</string>"
assert_has "testflight dry-run: plist CloudKit Production" "${OUT}" "<key>iCloudContainerEnvironment</key>"$'\n'"      | 	<string>Production</string>"
assert_has "testflight dry-run: plist is internal testing only" "${OUT}" "<key>testFlightInternalTestingOnly</key>"$'\n'"      | 	<true/>"
assert_has "testflight dry-run: plist keeps our build number" "${OUT}" "<key>manageAppVersionAndBuildNumber</key>"$'\n'"      | 	<false/>"
assert_has "testflight dry-run: says it uploads" "${OUT}" "upload to TestFlight (altool)"
assert_lacks "testflight dry-run never prints the team id" "${OUT}" "${FAKE_TEAM}"
assert_lacks "testflight dry-run never prints the key id" "${OUT}" "${FAKE_KEY_ID}"
assert_lacks "testflight dry-run never prints the issuer id" "${OUT}" "${FAKE_ISSUER}"
assert_lacks "testflight dry-run never prints the key path" "${OUT}" "${KEY}"
assert_has "testflight dry-run: says it is untested" "${OUT}" "not been tested"

# the dry-run plist is a valid property list
# (the printed plist shows the masked team as <BUDDY_TEAM_ID>, which is not valid XML text: put a stand-in back)
printf '%s\n' "${OUT}" | sed -n 's/^      | //p' | sed 's/<BUDDY_TEAM_ID>/TEAMID/' >"${WORK}/exportoptions.plist"
assert "testflight dry-run: the generated ExportOptions.plist is valid" plutil -lint "${WORK}/exportoptions.plist"
assert "testflight dry-run: the plist has method app-store-connect" bash -c '[ "$(plutil -extract method raw -o - "$1")" = "app-store-connect" ]' _ "${WORK}/exportoptions.plist"

run_case "${TEAM}" -- "${FLIGHT}" --dry-run --export-only --version 2.0.1
assert_rc "testflight --dry-run --export-only exits 0" 0
assert_has "testflight dry-run export-only: destination export" "${OUT}" "<string>export</string>"
assert_lacks "testflight dry-run export-only: no upload destination" "${OUT}" "<string>upload</string>"
assert_has "testflight dry-run export-only: verifies the .ipa" "${OUT}" "would verify on the exported .ipa"
assert_has "testflight dry-run export-only: checks the production push" "${OUT}" "aps-environment production"
assert_has "testflight dry-run: version given" "${OUT}" "MARKETING_VERSION=2.0.1"
assert_lacks "testflight dry-run export-only without a key has no authentication flags" "${OUT}" "-authenticationKeyPath"

run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --dry-run --upload-with xcodebuild --build 3
assert_rc "testflight --dry-run --upload-with xcodebuild exits 0" 0
assert_has "testflight dry-run xcodebuild: exports the local .ipa first" "${OUT}" "<string>export</string>"
assert_has "testflight dry-run xcodebuild: then signs and uploads with destination upload" "${OUT}" "<string>upload</string>"
assert_lacks "testflight dry-run xcodebuild: no altool" "${OUT}" "altool"
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --dry-run --upload-with=carrier-pigeon
assert_rc "testflight: an unknown --upload-with exits 2" 2
assert_has "testflight: an unknown --upload-with message" "${OUT}" "--upload-with must be altool or xcodebuild"
assert_has "testflight --help documents --upload-with" "$("${FLIGHT}" --help 2>&1)" "--upload-with"
assert_has "testflight --help says --upload-with xcodebuild uploads a file that was not verified" "$("${FLIGHT}" --help 2>&1)" "NOT the verified .ipa"

# the default build number is the UTC time, only digits, and grows
before_epoch="$(date -u +%s)"
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --dry-run
after_epoch="$(date -u +%s)"
build_default="$(sed -n 's/.*CURRENT_PROJECT_VERSION=\([0-9]*\).*/\1/p' <<<"${OUT}" | head -n 1)"
if printf '%s' "${build_default}" | grep -Eq '^[0-9]{12}$'; then pass "testflight: default build number is 12 digits (UTC YYYYMMDDHHMM)"; else fail "testflight: default build number is 12 digits (got '${build_default}')"; fi
# compared with the UTC minute before and after the run, so a minute or hour boundary cannot make it flaky
utc_before="$(date -u -r "${before_epoch}" +%Y%m%d%H%M)"
utc_after="$(date -u -r "${after_epoch}" +%Y%m%d%H%M)"
if [ "${build_default}" = "${utc_before}" ] || [ "${build_default}" = "${utc_after}" ]; then
  pass "testflight: the default build number is the UTC minute of the run"
else
  fail "testflight: the default build number is the UTC minute of the run (got ${build_default}, wanted ${utc_before} or ${utc_after})"
fi
assert_has "testflight: says where the build number came from" "${OUT}" "Build number from the UTC time"

# ---- testflight.sh: real runs with the fake tools --------------------------------------------------------------------

IPA="${WORK}/tf-real/testflight-build/export/BuddyPhone.ipa"

# A good --export-only run: archive, verify the archive, export a real zipped ad-hoc signed .ipa (fake export step),
# verify it. Every check really runs (codesign, plutil, ditto).
run_case "${TEAM}" -- "${FLIGHT}" --export-only --out-dir "${WORK}/tf-real" --build 5 --version 3.2.1
assert_rc "testflight real: a good --export-only run exits 0" 0
assert_has "testflight real: archived" "$(calls)" "archive"
assert_has "testflight real: archive verification ran (bundle id)" "${OUT}" "ok   bundle id is com.sergeyhovakimyan.buddy.phone"
assert_has "testflight real: checks the version" "${OUT}" "ok   version is 3.2.1"
assert_has "testflight real: checks the build number" "${OUT}" "ok   build number is 5"
assert_has "testflight real: checks the nested iOS app icon key" "${OUT}" "ok   the app icon is declared (CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconName AppIcon)"
assert_has "testflight real: checks the asset catalog" "${OUT}" "ok   the asset catalog is in the app (Assets.car)"
assert_has "testflight real: the archive Team check passes" "${OUT}" "ok   TeamIdentifier equals BUDDY_TEAM_ID"
assert_has "testflight real: checks the iCloud entitlements" "${OUT}" "ok   app has the iCloud container entitlement"
assert_has "testflight real: checks the CloudKit switch in Info.plist" "${OUT}" "ok   Info.plist turns CloudKit on (BuddyCloudKit true)"
assert_has "testflight real: the export ran with destination export" "$(calls)" "export-destination=export"
assert_lacks "testflight real: --export-only never uploads" "$(calls)" "export-destination=upload"
assert_lacks "testflight real: --export-only never calls altool" "$(calls)" "altool"
assert_has "testflight real: the .ipa check ran" "${OUT}" "==> Verifying the exported .ipa"
assert_has "testflight real: the .ipa holds the app" "${OUT}" "ok   the .ipa holds Payload/BuddyPhone.app"
assert_has "testflight real: .ipa codesign" "${OUT}" "ok   codesign --verify --deep --strict on the exported app"
assert_has "testflight real: .ipa team" "${OUT}" "ok   TeamIdentifier equals BUDDY_TEAM_ID"
assert_has "testflight real: .ipa version" "${OUT}" "ok   version is 3.2.1"
assert_has "testflight real: .ipa build number" "${OUT}" "ok   build number is 5"
assert_has "testflight real: .ipa aps-environment production" "${OUT}" "ok   aps-environment is production"
assert_has "testflight real: .ipa container environment Production" "${OUT}" "ok   icloud-container-environment is Production"
assert_has "testflight real: .ipa not debuggable" "${OUT}" "ok   app is not debuggable (get-task-allow is not true)"
assert_lacks "testflight real: no failed check" "${OUT}" "FAIL"
assert_has "testflight real: the summary says signed, verified, NOT uploaded" "${OUT}" "signed and verified, NOT uploaded"
assert "testflight real: the .ipa really exists and is a zip with Payload/" bash -c 'unzip -l "$1" | grep -q "Payload/BuddyPhone.app/Info.plist"' _ "${IPA}"
assert "testflight real: the build folder is owner-only (700)" bash -c '[ "$(stat -f %Lp "$1")" = "700" ]' _ "${WORK}/tf-real/testflight-build"
assert "testflight real: removes its temp folder" no_tmp_left
assert_lacks "testflight real: never prints the team id" "${OUT}" "${FAKE_TEAM}"
assert_lacks "testflight real: never prints the key path" "${OUT}" "${KEY}"

# A good full run with altool: upload the verified .ipa, after verifying it.
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --out-dir "${WORK}/tf-up" --build 6
assert_rc "testflight real: a good upload run exits 0" 0
assert_has "testflight real: altool uploads the exported .ipa" "$(calls)" "xcrun altool --upload-app -f ${WORK}/tf-up/testflight-build/export/BuddyPhone.ipa --api-key ${FAKE_KEY_ID} --api-issuer ${FAKE_ISSUER} --p8-file-path ${KEY}"
assert_has "testflight real: the upload used the exported .ipa, destination export" "$(calls)" "export-destination=export"
assert_lacks "testflight real: no second export with destination upload" "$(calls)" "export-destination=upload"
assert "testflight real: the .ipa is verified before altool runs" bash -c '[ -n "$1" ] && o="$2" && [ "${o%%Uploading to App Store Connect*}" != "${o}" ] && v="${o%%Uploading to App Store Connect*}" && case "${v}" in *"Verifying the exported .ipa"*) exit 0;; esac; exit 1' _ x "${OUT}"
assert_has "testflight real: the summary says it was uploaded" "${OUT}" "Uploaded BuddyPhone"
assert_lacks "testflight real: an upload run never prints the key id" "${OUT}" "${FAKE_KEY_ID}"
assert_lacks "testflight real: an upload run never prints the issuer id" "${OUT}" "${FAKE_ISSUER}"
assert_lacks "testflight real: an upload run never prints the key path" "${OUT}" "${KEY}"
assert_lacks "testflight real: an upload run never prints the team id" "${OUT}" "${FAKE_TEAM}"

# --upload-with xcodebuild: export, verify, then export again with destination upload.
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --out-dir "${WORK}/tf-xb" --build 6 --upload-with xcodebuild
assert_rc "testflight real: a good --upload-with xcodebuild run exits 0" 0
assert_has "testflight real: xcodebuild upload: first export is local" "$(calls)" "export-destination=export"
assert_has "testflight real: xcodebuild upload: then the upload export" "$(calls)" "export-destination=upload"
assert_lacks "testflight real: xcodebuild upload: no altool" "$(calls)" "altool"
assert_has "testflight real: xcodebuild upload warns that the uploaded package is signed again" "${OUT}" "signs the package again"

# The icon check reads the NESTED iOS key. A top-level CFBundleIconName (the macOS layout) does not count, a missing icon fails.
run_case "${TEAM}" FAKE_NO_ICON=1 -- "${FLIGHT}" --export-only --out-dir "${WORK}/tf-neg" --build 5
assert_rc_nonzero "testflight real: an archive without an app icon fails"
assert_has "testflight real: the icon check fails" "${OUT}" "FAIL the app icon is declared"
assert_has "testflight real: nothing is exported after a failed archive verification" "${OUT}" "nothing was exported or uploaded"
assert_lacks "testflight real: no export after a failed archive verification" "$(calls)" "-exportArchive"
run_case "${TEAM}" FAKE_TOPLEVEL_ICON=1 -- "${FLIGHT}" --export-only --out-dir "${WORK}/tf-neg" --build 5
assert_rc_nonzero "testflight real: a top-level CFBundleIconName (macOS layout) is not accepted on iOS"
assert_has "testflight real: the top-level icon fails the icon check" "${OUT}" "FAIL the app icon is declared"
run_case "${TEAM}" FAKE_NO_CLOUD_FLAG=1 -- "${FLIGHT}" --export-only --out-dir "${WORK}/tf-neg" --build 5
assert_rc_nonzero "testflight real: an archive without BuddyCloudKit fails"
assert_has "testflight real: the CloudKit switch check fails" "${OUT}" "FAIL Info.plist turns CloudKit on (BuddyCloudKit true)"
assert_lacks "testflight real: no export without the CloudKit switch" "$(calls)" "-exportArchive"
run_case "${TEAM}" FAKE_TEAM_ID=ZZOTHER000 -- "${FLIGHT}" --export-only --out-dir "${WORK}/tf-neg" --build 5
assert_rc_nonzero "testflight real: the wrong team on the archive fails"
assert_has "testflight real: the archive Team check fails" "${OUT}" "FAIL TeamIdentifier equals BUDDY_TEAM_ID"
assert_lacks "testflight real: no export after a wrong-team archive" "$(calls)" "-exportArchive"
assert "testflight real: failures leave no temp folder" no_tmp_left

# Bad .ipa variants: each must stop before the upload.
ipa_case() { # ipa_case <name> <variant> <failing check> [VAR=value ...]
  local name="$1" variant="$2" failing="$3"
  shift 3
  run_case "${TEAM}" "${ASC[@]}" FAKE_IPA_VARIANT="${variant}" "$@" -- "${FLIGHT}" --out-dir "${WORK}/tf-ipa" --build 5
  assert_rc_nonzero "testflight real: ${name} fails the run"
  assert_has "testflight real: ${name}: the check fails" "${OUT}" "FAIL ${failing}"
  assert_has "testflight real: ${name}: says the .ipa was not uploaded" "${OUT}" "was not uploaded"
  assert_lacks "testflight real: ${name}: altool is never called" "$(calls)" "altool"
  assert_lacks "testflight real: ${name}: no upload export" "$(calls)" "export-destination=upload"
  assert_lacks "testflight real: ${name}: nothing sensitive is printed" "${OUT}" "${FAKE_KEY_ID}"
}
ipa_case "an .ipa with aps-environment development" aps-dev "aps-environment is production"
ipa_case "an .ipa without icloud-container-environment" no-container-env "icloud-container-environment is Production"
ipa_case "an .ipa with get-task-allow" get-task-allow "app is not debuggable"
ipa_case "an .ipa with the wrong build number" wrong-build "build number is 5"
ipa_case "an .ipa signed by the wrong team" good "TeamIdentifier equals BUDDY_TEAM_ID" FAKE_IPA_TEAM=ZZOTHER000
assert_lacks "testflight real: the wrong team id is not printed" "${OUT}" "ZZOTHER000"
run_case "${TEAM}" "${ASC[@]}" FAKE_IPA_VARIANT=no-ipa -- "${FLIGHT}" --out-dir "${WORK}/tf-ipa" --build 5
assert_rc_nonzero "testflight real: an export that produces no .ipa fails the run"
assert_has "testflight real: a missing .ipa is reported" "${OUT}" "FAIL the .ipa exists"
assert_lacks "testflight real: a missing .ipa is never uploaded" "$(calls)" "altool"
# an .ipa that is not a zip: ditto fails and says so
cat >"${WORK}/fakebin/ditto" <<'FAKE'
#!/bin/bash
if [ "$1" = "-x" ]; then echo "ditto: fake unpack failure" >&2; exit 1; fi
exec /usr/bin/ditto "$@"
FAKE
chmod +x "${WORK}/fakebin/ditto"
run_case "${TEAM}" "${ASC[@]}" -- "${FLIGHT}" --out-dir "${WORK}/tf-ditto" --build 5
assert_rc_nonzero "testflight real: a failing ditto fails the run"
assert_has "testflight real: a failing ditto prints a message" "${OUT}" "Could not unpack"
assert_lacks "testflight real: a failing ditto uploads nothing" "$(calls)" "altool"
rm -f "${WORK}/fakebin/ditto"

# Failures print hints (masked): no app record, agreements, key role, build number, devices.
hints_have() { # hints_have <label>
  assert_has "$1: hint no App Store Connect app record" "${OUT}" "No suitable application records were found"
  assert_has "$1: hint create the app record" "${OUT}" "create it in App Store Connect"
  assert_has "$1: hint license agreement" "${OUT}" "License Agreement"
  assert_has "$1: hint key role Admin" "${OUT}" "use an Admin key"
  assert_has "$1: hint build number" "${OUT}" "is not higher than the last upload"
  assert_lacks "$1: never prints the team id" "${OUT}" "${FAKE_TEAM}"
  assert_lacks "$1: never prints the key id" "${OUT}" "${FAKE_KEY_ID}"
  assert_lacks "$1: never prints the issuer id" "${OUT}" "${FAKE_ISSUER}"
  assert_lacks "$1: never prints the key path" "${OUT}" "${KEY}"
}
run_case "${TEAM}" "${ASC[@]}" FAKE_FAIL=export -- "${FLIGHT}" --out-dir "${WORK}/tf-f1" --build 5
assert_rc_nonzero "testflight real: a failed export fails the run"
assert_has "testflight real: a failed export says so" "${OUT}" "The export failed"
assert_lacks "testflight real: a failed export uploads nothing" "$(calls)" "altool"
hints_have "testflight real: failed export"
run_case "${TEAM}" "${ASC[@]}" FAKE_ALTOOL_RC=1 -- "${FLIGHT}" --out-dir "${WORK}/tf-f2" --build 5
assert_rc_nonzero "testflight real: a failed altool upload fails the run"
assert_has "testflight real: a failed upload says so" "${OUT}" "The upload failed"
assert_has "testflight real: the upload failure shows the export was verified first" "${OUT}" "ok   aps-environment is production"
hints_have "testflight real: failed upload"
run_case "${TEAM}" "${ASC[@]}" FAKE_FAIL=upload -- "${FLIGHT}" --out-dir "${WORK}/tf-f3" --build 5 --upload-with xcodebuild
assert_rc_nonzero "testflight real: a failed xcodebuild upload fails the run"
hints_have "testflight real: failed xcodebuild upload"
run_case "${TEAM}" "${ASC[@]}" FAKE_FAIL=archive -- "${FLIGHT}" --out-dir "${WORK}/tf-f4" --build 5
assert_rc_nonzero "testflight real: a failed archive fails the run"
assert_has "testflight real: a failed archive says so" "${OUT}" "The archive failed"
assert_has "testflight real: a failed archive hints at the missing device (M1)" "${OUT}" "Your team has no devices"
assert_has "testflight real: a failed archive points to --register-device" "${OUT}" "phone-signed-build.sh --register-device"
assert_has "testflight real: a failed archive hints at the agreement" "${OUT}" "License Agreement"
assert_has "testflight real: a failed archive hints at the key role" "${OUT}" "Admin"
assert_lacks "testflight real: a failed archive masks tool output" "${OUT}" "${FAKE_TEAM}"
assert_lacks "testflight real: a failed archive never exports" "$(calls)" "-exportArchive"
assert "testflight real: failures leave no temp folder (after the upload and export failures)" no_tmp_left

# ---- robustness of the scripts' own folder lookup ---------------------------------------------------------------------

mkdir -p "${WORK}/links" "${WORK}/decoy/scripts/lib" "${WORK}/decoy/lib"
ln -s "${PHONE}" "${WORK}/links/phone-link"
ln -s "phone-link" "${WORK}/links/phone-link2"
ln -s "${FLIGHT}" "${WORK}/links/flight-link"
ln -s "${SCRIPT_DIR}/release.sh" "${WORK}/links/release-link"
for l in phone-link phone-link2; do
  run_case "${TEAM}" -- "${WORK}/links/${l}" --dry-run --device DEVICE-0000-0001
  assert_rc "symlink ${l}: the script finds its lib and runs" 0
  assert_has "symlink ${l}: dry run works" "${OUT}" "Dry run finished"
done
run_case "${TEAM}" "${ASC[@]}" -- "${WORK}/links/flight-link" --dry-run --build 3
assert_rc "symlink: testflight.sh finds its lib and runs" 0
run_case -- "${WORK}/links/release-link" --help
assert_rc "symlink: release.sh --help works through a symlink" 0
assert_has "symlink: release.sh --help shows usage" "${OUT}" "Usage"
# an exported CDPATH that contains a folder named like ours must not redirect `cd`
run_case "${TEAM}" CDPATH="${WORK}/decoy:${WORK}" -- bash -c 'cd "$1" && exec scripts/phone-signed-build.sh --dry-run --device DEVICE-0000-0001' _ "${REPO_ROOT}"
assert_rc "CDPATH set: phone-signed-build.sh run by a relative path still works" 0
assert_has "CDPATH set: phone dry run works" "${OUT}" "Dry run finished"
run_case "${TEAM}" "${ASC[@]}" CDPATH="${WORK}/decoy:${WORK}" -- bash -c 'cd "$1" && exec scripts/testflight.sh --dry-run --build 3' _ "${REPO_ROOT}"
assert_rc "CDPATH set: testflight.sh run by a relative path still works" 0
run_case CDPATH="${WORK}/decoy:${WORK}" -- bash -c 'cd "$1" && exec scripts/release.sh --help' _ "${REPO_ROOT}"
assert_rc "CDPATH set: release.sh run by a relative path still works" 0
rm -rf "${WORK}/decoy" "${WORK}/links"

# ---- the API key file permission warning ------------------------------------------------------------------------------

for mode in 400 600 500 700; do
  rm -f "${WORK}/perm.p8"
  printf 'x' >"${WORK}/perm.p8"
  chmod "${mode}" "${WORK}/perm.p8"
  run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/perm.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --dry-run --device DEVICE-0000-0001
  assert_rc "key mode ${mode}: accepted" 0
  assert_lacks "key mode ${mode} (owner only): no permission warning" "${OUT}" "accessible to other users"
done
for mode in 640 644 604 664; do
  chmod "${mode}" "${WORK}/perm.p8"
  run_case "${TEAM}" BUDDY_ASC_KEY_PATH="${WORK}/perm.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" -- "${PHONE}" --dry-run --device DEVICE-0000-0001
  assert_has "key mode ${mode} (others can read): permission warning" "${OUT}" "accessible to other users"
done
rm -f "${WORK}/perm.p8"

# ---- the shared library (masking), exercised directly ----------------------------------------------------------------

lib_out="$(env -i PATH="${PATH}" bash -c '
  set -euo pipefail
  DRY_RUN=1
  usage() { :; }
  . "$1"
  add_mask "AB.C*D" "<X>"
  add_mask "/tmp/some path/key.p8" "<KEY>"
  add_mask "Team123456" "<TEAM>" I
  mask "a AB.C*D b ABXCCD /tmp/some path/key.p8 team123456 TEAM123456"
' _ "${COMMON}")"
# a key path that contains the team id: the longer value (the path) is masked first, so no half-masked path is left
lib_out2="$(env -i PATH="${PATH}" bash -c '
  set -euo pipefail
  DRY_RUN=1
  usage() { :; }
  . "$1"
  add_mask "ZZTEST0000" "<TEAM>" I
  add_mask "/keys/ZZTEST0000/AuthKey_ABC.p8" "<KEY>"
  mask "at /keys/ZZTEST0000/AuthKey_ABC.p8 team zztest0000"
' _ "${COMMON}")"
assert_has "mask: a key path containing the team id is masked as a whole" "${lib_out2}" "at <KEY> team <TEAM>"
assert_lacks "mask: no half-masked key path is left" "${lib_out2}" "/keys/"
assert_has "mask: regular expression characters in a secret are taken literally" "${lib_out}" "a <X> b ABXCCD"
assert_has "mask: a path with a space is masked" "${lib_out}" "b ABXCCD <KEY>"
assert_has "mask: the Team ID is masked case-insensitively" "${lib_out}" "<KEY> <TEAM> <TEAM>"

# ---- the placeholder app icons -------------------------------------------------------------------------------------

PHONE_ICONS="${REPO_ROOT}/Apps/BuddyPhone/Assets.xcassets/AppIcon.appiconset"
MAC_ICONS="${REPO_ROOT}/Apps/BuddyMac/Assets.xcassets/AppIcon.appiconset"
assert "iPhone AppIcon Contents.json parses" plutil -convert xml1 -o /dev/null "${PHONE_ICONS}/Contents.json"
assert "Mac AppIcon Contents.json parses" plutil -convert xml1 -o /dev/null "${MAC_ICONS}/Contents.json"
assert "iPhone icon is 1024 px wide" test "$(sips -g pixelWidth "${PHONE_ICONS}/icon-1024.png" | sed -n 's/.*pixelWidth: //p')" = "1024"
assert "iPhone icon is 1024 px high" test "$(sips -g pixelHeight "${PHONE_ICONS}/icon-1024.png" | sed -n 's/.*pixelHeight: //p')" = "1024"
assert "iPhone icon has no alpha channel (App Store Connect requirement)" test "$(sips -g hasAlpha "${PHONE_ICONS}/icon-1024.png" | sed -n 's/.*hasAlpha: //p')" = "no"
assert "iPhone icon set names the 1024 universal ios icon" bash -c '[ "$(plutil -extract images.0.size raw -o - "$1")" = "1024x1024" ] && [ "$(plutil -extract images.0.idiom raw -o - "$1")" = "universal" ] && [ "$(plutil -extract images.0.platform raw -o - "$1")" = "ios" ]' _ "${PHONE_ICONS}/Contents.json"
for px in 16 32 64 128 256 512 1024; do
  assert "Mac icon ${px}.png is ${px} px" test "$(sips -g pixelWidth "${MAC_ICONS}/icon-${px}.png" | sed -n 's/.*pixelWidth: //p')" = "${px}"
done
assert "Mac icon set lists 10 images (5 sizes at 1x and 2x)" test "$(plutil -extract images raw -o - "${MAC_ICONS}/Contents.json")" = "10"
assert "every Mac icon file named in Contents.json exists" bash -c 'for i in 0 1 2 3 4 5 6 7 8 9; do f="$(plutil -extract "images.$i.filename" raw -o - "$1/Contents.json")"; [ -f "$1/$f" ] || exit 1; done' _ "${MAC_ICONS}"
assert "project.yml wires the BuddyPhone icon" bash -c 'awk "/^  BuddyPhone:/{p=1} /^  BuddyPhoneTests:/{p=0} p && /ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon/{f=1} END{exit !f}" "$1"' _ "${REPO_ROOT}/Apps/project.yml"
assert "project.yml wires the BuddyMac icon" bash -c 'awk "/^  BuddyMac:/{p=1} /^  BuddyHook:/{p=0} p && /ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon/{f=1} END{exit !f}" "$1"' _ "${REPO_ROOT}/Apps/project.yml"
assert "the unit-test targets do not carry the app icon catalog" bash -c '[ "$(grep -c "^          - Assets.xcassets" "$1")" = "2" ]' _ "${REPO_ROOT}/Apps/project.yml"
assert "make-icons.swift loads no existing artwork (it draws from scratch)" bash -c '! grep -qE "NSImage\(|UIImage\(|CGImageSourceCreate|contentsOf" "$1"' _ "${SCRIPT_DIR}/make-icons.swift"
if command -v swiftc >/dev/null 2>&1; then
  # swiftc leaves a TemporaryDirectory.* folder in TMPDIR; give it one inside WORK, which the trap removes.
  mkdir -p "${WORK}/swiftc-tmp"
  assert "make-icons.swift type-checks (not run)" env TMPDIR="${WORK}/swiftc-tmp" swiftc -typecheck "${SCRIPT_DIR}/make-icons.swift"
else
  printf 'skip swiftc type-check (swiftc not found)\n'
fi

# ---- hygiene -------------------------------------------------------------------------------------------------------

assert "the new scripts and tests contain no key material" bash -c '! grep -l "BEGIN .*PRIVATE KEY" "$@"' _ "${PHONE}" "${FLIGHT}" "${COMMON}"
assert "no .p8 key file is tracked in the repo" bash -c '[ -z "$(git -C "$1" ls-files "*.p8" "*.mobileprovision" "*.cer" "*.p12")" ]' _ "${REPO_ROOT}"
assert "dist/ is git-ignored (build output and archives)" bash -c 'git -C "$1" check-ignore -q dist/x' _ "${REPO_ROOT}"

printf '\n%d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]
