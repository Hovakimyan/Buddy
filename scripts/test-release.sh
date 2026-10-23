#!/usr/bin/env bash
#
# Tests for scripts/release.sh. Runs the UNSIGNED build end to end (a real Release build, takes a few minutes the
# first time), and checks --help, argument errors and the signed mode's early failure and dry-run output. Also checks
# the app's sounds: one per SoundCue in sounds/block, short PCM files, every file listed in SOURCES.md with CC0, and
# runs check-names.sh on the tree and on the built app (no outside product or character names).
#
# Safe by design: output goes to a temp folder, the dmg is mounted only at a temp mount point (and detached), no
# app is launched or installed, no real signing identity or notary profile is used (a fake identity name makes the
# signed mode fail before anything is built), and no Application Support folder or Claude settings file is touched.
#
# Usage: scripts/test-release.sh [--skip-build]   (--skip-build runs only the fast checks)

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
RELEASE="${SCRIPT_DIR}/release.sh"
CHECK_NAMES="${SCRIPT_DIR}/check-names.sh"

SKIP_BUILD=0
case "${1:-}" in
  "") ;;
  --skip-build) SKIP_BUILD=1 ;;
  *)
    echo "usage: $0 [--skip-build]" >&2
    exit 2
    ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/buddy-release-test.XXXXXX")"
MNT="${WORK}/mnt"
# Always detach our own mount (even after Ctrl-C), and never rm -rf into a folder that is still a mount point.
cleanup() {
  if [ -d "${MNT}" ] && [ "$(stat -f %d "${MNT}")" != "$(stat -f %d "${WORK}")" ]; then
    hdiutil detach "${MNT}" -quiet >/dev/null 2>&1 || hdiutil detach "${MNT}" -force -quiet >/dev/null 2>&1 || true
  fi
  if [ -d "${MNT}" ] && [ "$(stat -f %d "${MNT}")" != "$(stat -f %d "${WORK}")" ]; then
    echo "warning: ${MNT} is still mounted; leaving ${WORK} in place" >&2
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT
# Everything below (release.sh, its xcodebuild, hdiutil) gets a TMPDIR inside WORK: xcodebuild otherwise leaves
# <path>_SourcePackages_workspace-state.json.lock files in the real TMPDIR on every run. The trap removes them with WORK.
mkdir -p "${WORK}/tmp"
export TMPDIR="${WORK}/tmp"

FAKE_TEAM="ZZTEST0000"
FAKE_IDENTITY="Buddy Nonexistent Test Identity ZZ"

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
# assert "<name>" <command...>
assert() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi
}
not() { ! "$@"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
# assert_has "<name>" "<haystack>" "<needle>"
assert_has() {
  if contains "$2" "$3"; then pass "$1"; else fail "$1 (missing: $3)" "$2"; fi
}
assert_lacks() {
  if contains "$2" "$3"; then fail "$1 (unexpected: $3)" "$2"; else pass "$1"; fi
}

# Run release.sh capturing stdout+stderr in $OUT and the exit code in $RC.
OUT=""
RC=0
run_release() {
  set +e
  OUT="$("${RELEASE}" "$@" 2>&1)"
  RC=$?
  set -e
}

# ---- static --------------------------------------------------------------------------------------------------------

assert "release.sh is executable" test -x "${RELEASE}"
assert "bash -n release.sh" bash -n "${RELEASE}"
assert "bash -n test-release.sh" bash -n "${BASH_SOURCE[0]}"
assert "check-names.sh is executable" test -x "${CHECK_NAMES}"
assert "bash -n check-names.sh" bash -n "${CHECK_NAMES}"
if command -v shellcheck >/dev/null 2>&1; then
  assert "shellcheck release.sh" shellcheck "${RELEASE}"
  assert "shellcheck check-names.sh" shellcheck "${CHECK_NAMES}"
else
  printf 'skip shellcheck (not installed)\n'
fi

# ---- no outside names (scripts/check-names.sh; the built app is checked after the end-to-end build) -------------------

set +e
names_out="$("${CHECK_NAMES}" 2>&1)"
names_rc=$?
set -e
[ "${names_rc}" -eq 0 ] && pass "check-names.sh: no outside names in the tracked files" \
  || fail "check-names.sh: no outside names in the tracked files (rc=${names_rc})" "${names_out}"

# ---- --help and argument errors -------------------------------------------------------------------------------------

run_release --help
[ "${RC}" -eq 0 ] && pass "--help exits 0" || fail "--help exits 0 (rc=${RC})"
assert_has "--help shows usage" "${OUT}" "Usage: scripts/release.sh"
assert_has "--help documents --version" "${OUT}" "--version X.Y.Z"
assert_has "--help documents BUDDY_TEAM_ID" "${OUT}" "BUDDY_TEAM_ID"
assert_has "--help documents --build" "${OUT}" "--build N"
assert_has "--help documents the API key variables" "${OUT}" "BUDDY_ASC_KEY_PATH"
assert_has "--help gives the macOS 15 way to open an unsigned app" "${OUT}" "Open Anyway"
assert_lacks "--help has no outdated right-click hint" "${OUT}" "right-click"

# the docs carry the macOS 15 wording, not the outdated right-click > Open
doc_files=("${SCRIPT_DIR}/README.md" "${SCRIPT_DIR}/release.sh" "${SCRIPT_DIR}/../README.md" "${SCRIPT_DIR}/../Apps/README.md")
assert "docs and script no longer say right-click" bash -c '! grep -il "right-click" "$@"' _ "${doc_files[@]}"
assert "scripts/README.md says Open Anyway" grep -Fq "Open Anyway" "${SCRIPT_DIR}/README.md"

run_release --frobnicate
[ "${RC}" -ne 0 ] && pass "unknown flag exits non-zero" || fail "unknown flag exits non-zero"
assert_has "unknown flag is named in the error" "${OUT}" "Unknown option: --frobnicate"

run_release --version "1.x"
[ "${RC}" -ne 0 ] && pass "invalid version exits non-zero" || fail "invalid version exits non-zero"
assert_has "invalid version message" "${OUT}" "Invalid version"

run_release --version
[ "${RC}" -ne 0 ] && pass "--version without a value exits non-zero" || fail "--version without a value exits non-zero"

# ---- default version comes from project.yml --------------------------------------------------------------------------

yml_version="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "${SCRIPT_DIR}/../Apps/project.yml" | head -n 1)"
run_release --dry-run --unsigned --out-dir "${WORK}/dry"
[ "${RC}" -eq 0 ] && pass "unsigned --dry-run exits 0" || fail "unsigned --dry-run exits 0 (rc=${RC})" "${OUT}"
assert_has "default version is MARKETING_VERSION from project.yml (${yml_version})" "${OUT}" "Buddy-${yml_version}.dmg"
assert_has "dry-run prints the Release xcodebuild" "${OUT}" "-configuration Release"
assert_has "dry-run prints hdiutil create UDZO" "${OUT}" "-format UDZO"
assert_has "dry-run names the volume Buddy" "${OUT}" "-volname Buddy"
assert_lacks "unsigned dry-run has no hardened runtime" "${OUT}" "ENABLE_HARDENED_RUNTIME"
assert_lacks "unsigned dry-run has no entitlements override" "${OUT}" "BUDDY_ENTITLEMENTS"
assert "dry-run creates nothing" test ! -e "${WORK}/dry"

# --unsigned wins over BUDDY_TEAM_ID, and the team id never shows up
BUDDY_TEAM_ID="${FAKE_TEAM}" run_release --dry-run --unsigned --version 1.2.3 --out-dir "${WORK}/dry"
[ "${RC}" -eq 0 ] && pass "--unsigned with BUDDY_TEAM_ID exits 0" || fail "--unsigned with BUDDY_TEAM_ID exits 0 (rc=${RC})" "${OUT}"
assert_has "--unsigned forces unsigned mode" "${OUT}" "unsigned mode"
assert_lacks "--unsigned does not pass DEVELOPMENT_TEAM" "${OUT}" "DEVELOPMENT_TEAM"
assert_lacks "--unsigned does not print the team id" "${OUT}" "${FAKE_TEAM}"

# ---- signed mode: certificate resolution (fake identities file seam, nothing is built) -------------------------------

HASH_A="0123456789ABCDEF0123456789ABCDEF01234567"
HASH_B="89ABCDEF0123456789ABCDEF0123456789ABCDEF"
FULL_NAME="Developer ID Application: Example Co (${FAKE_TEAM})"
printf '  1) %s "%s"\n     1 valid identities found\n' "${HASH_A}" "${FULL_NAME}" >"${WORK}/ids-one.txt"
printf '  1) %s "%s"\n  2) %s "%s"\n     2 valid identities found\n' "${HASH_A}" "${FULL_NAME}" "${HASH_B}" "${FULL_NAME}" >"${WORK}/ids-two.txt"
printf '  1) %s "Developer ID Application: Other Co (OTHER12345)"\n     1 valid identities found\n' "${HASH_A}" >"${WORK}/ids-other.txt"
: >"${WORK}/ids-none.txt"

# no matching certificate: the real keychain with a fake identity name
BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FAKE_IDENTITY}" BUDDY_NOTARY_PROFILE="no-such-profile" \
  run_release --version 1.2.3 --out-dir "${WORK}/signed-fail"
[ "${RC}" -ne 0 ] && pass "signed mode without a matching certificate exits non-zero" || fail "signed mode without a matching certificate exits non-zero"
assert_has "missing certificate message" "${OUT}" "No valid code signing certificate"
assert_has "missing certificate message points at the keychain check" "${OUT}" "security find-identity -v -p codesigning"
assert_lacks "failure output does not print the team id" "${OUT}" "${FAKE_TEAM}"
assert "early failure builds nothing" test ! -e "${WORK}/signed-fail"

# zero matches (an empty keychain, and another team's certificate)
BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-none.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_NOTARY_PROFILE="x" \
  run_release --version 1.2.3 --out-dir "${WORK}/signed-fail"
[ "${RC}" -ne 0 ] && pass "zero certificates: exits non-zero" || fail "zero certificates: exits non-zero"
assert_has "zero certificates: clear message" "${OUT}" "No valid code signing certificate"

BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-other.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_NOTARY_PROFILE="x" \
  run_release --version 1.2.3 --out-dir "${WORK}/signed-fail"
[ "${RC}" -ne 0 ] && pass "another team's certificate: exits non-zero" || fail "another team's certificate: exits non-zero"
assert_has "another team's certificate is listed as not usable" "${OUT}" "other teams"

# two matches: ambiguous, candidates listed without the team id
BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-two.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_NOTARY_PROFILE="x" \
  run_release --version 1.2.3 --out-dir "${WORK}/signed-fail"
[ "${RC}" -ne 0 ] && pass "ambiguous certificates: exits non-zero" || fail "ambiguous certificates: exits non-zero"
assert_has "ambiguous certificates: says so" "${OUT}" "ambiguous"
assert_has "ambiguous certificates: lists candidate 1" "${OUT}" "${HASH_A}"
assert_has "ambiguous certificates: lists candidate 2" "${OUT}" "${HASH_B}"
assert_lacks "ambiguous certificates: team id masked" "${OUT}" "${FAKE_TEAM}"
assert "ambiguity builds nothing" test ! -e "${WORK}/signed-fail"

# the same certificate listed twice (two keychains) is one certificate, not an ambiguity
printf '  1) %s "%s"\n  2) %s "%s"\n     2 valid identities found\n' "${HASH_A}" "${FULL_NAME}" "${HASH_A}" "${FULL_NAME}" >"${WORK}/ids-dup.txt"
BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-dup.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME}" BUDDY_NOTARY_PROFILE="x" \
  run_release --dry-run --version 1.2.3 --out-dir "${WORK}/signed-fail"
[ "${RC}" -eq 0 ] && pass "the same certificate in two keychains is accepted" || fail "the same certificate in two keychains is accepted (rc=${RC})" "${OUT}"
assert_lacks "the same certificate in two keychains is not ambiguous" "${OUT}" "ambiguous"
assert_has "the same certificate in two keychains resolves to its hash" "${OUT}" "${HASH_A}"

# the test seam is loud
assert_has "the test seam warns when it is active" "${OUT}" "test seam active"
assert_has "the seam warning says to unset it" "${OUT}" "Unset it for a real release"

# the mask is case-insensitive
BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME} zztest0000" BUDDY_NOTARY_PROFILE="x" \
  run_release --dry-run --version 1.2.3 --out-dir "${WORK}/signed-fail"
assert_lacks "a lower-case team id in an argument is masked too" "${OUT}" "zztest0000"

# invalid team id and partial API key settings
BUDDY_TEAM_ID="short" run_release --dry-run
[ "${RC}" -ne 0 ] && pass "a malformed BUDDY_TEAM_ID is rejected" || fail "a malformed BUDDY_TEAM_ID is rejected"
BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_ASC_KEY_ID="KEYID" BUDDY_NOTARY_PROFILE="x" \
  run_release --version 1.2.3 --out-dir "${WORK}/signed-fail"
[ "${RC}" -ne 0 ] && pass "a partial BUDDY_ASC_* set is rejected" || fail "a partial BUDDY_ASC_* set is rejected"
assert_has "a partial BUDDY_ASC_* set: message" "${OUT}" "all of BUDDY_ASC_KEY_PATH"

# ---- signed mode: dry-run prints the exact commands, masks the team, never contacts Apple -----------------------------

# A fake xcrun that records every call: a dry run must not call it at all (no notarytool history, nothing).
mkdir -p "${WORK}/fakebin"
printf '#!/bin/sh\necho "$@" >> "%s/xcrun.calls"\nexit 1\n' "${WORK}" >"${WORK}/fakebin/xcrun"
chmod +x "${WORK}/fakebin/xcrun"
printf 'fake-key' >"${WORK}/AuthKey.p8"
chmod 600 "${WORK}/AuthKey.p8"
# Fake App Store Connect values, 10 character key id and a UUID issuer, as common.sh's format checks require. They must never
# appear in any output.
FAKE_KEY_ID="ZZKEY12345"
FAKE_ISSUER="12345678-aaaa-bbbb-cccc-1234567890ab"

PATH="${WORK}/fakebin:${PATH}" BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" \
  BUDDY_SIGN_IDENTITY="${FULL_NAME}" BUDDY_NOTARY_PROFILE="no-such-profile" \
  BUDDY_ASC_KEY_PATH="${WORK}/AuthKey.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" \
  run_release --dry-run --version 1.2.3 --build 7 --out-dir "${WORK}/signed-dry"
[ "${RC}" -eq 0 ] && pass "signed --dry-run exits 0" || fail "signed --dry-run exits 0 (rc=${RC})" "${OUT}"
assert_has "signed dry-run: archives" "${OUT}" "xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -configuration Release"
assert_has "signed dry-run: archive action" "${OUT}" "archive"
assert_has "signed dry-run: exportArchive" "${OUT}" "-exportArchive"
assert_has "signed dry-run: hardened runtime" "${OUT}" "ENABLE_HARDENED_RUNTIME=YES"
assert_has "signed dry-run: archives with the development cloud entitlements" "${OUT}" "BUDDY_ENTITLEMENTS=BuddyMac/BuddyMac.cloud.entitlements"
assert_lacks "signed dry-run: no device registration unless asked" "${OUT}" "-allowProvisioningDeviceRegistration"
assert_has "signed dry-run: team passed (masked)" "${OUT}" "DEVELOPMENT_TEAM=<BUDDY_TEAM_ID>"
assert_has "signed dry-run: provisioning updates" "${OUT}" "-allowProvisioningUpdates"
assert_has "signed dry-run: version passed" "${OUT}" "MARKETING_VERSION=1.2.3"
assert_has "signed dry-run: build number passed" "${OUT}" "CURRENT_PROJECT_VERSION=7"
assert_has "signed dry-run: export plist method" "${OUT}" "<string>developer-id</string>"
assert_has "signed dry-run: export plist team (masked)" "${OUT}" "<string><BUDDY_TEAM_ID></string>"
assert_has "signed dry-run: export plist uses the resolved SHA-1" "${OUT}" "<string>${HASH_A}</string>"
assert_has "signed dry-run: export plist Production container" "${OUT}" "<key>iCloudContainerEnvironment</key>"
assert_has "signed dry-run: API key flags are passed (values masked)" "${OUT}" "-authenticationKeyID '<BUDDY_ASC_KEY_ID>'"
assert_has "signed dry-run: key path is masked" "${OUT}" "-authenticationKeyPath '<BUDDY_ASC_KEY_PATH>'"
assert_has "signed dry-run: issuer id is masked" "${OUT}" "-authenticationKeyIssuerID '<BUDDY_ASC_ISSUER_ID>'"
assert_lacks "signed dry-run never prints the key id" "${OUT}" "${FAKE_KEY_ID}"
assert_lacks "signed dry-run never prints the issuer id" "${OUT}" "${FAKE_ISSUER}"
assert_lacks "signed dry-run never prints the key path" "${OUT}" "${WORK}/AuthKey.p8"
assert_lacks "signed dry-run never prints the key file name" "${OUT}" "AuthKey.p8"
assert_has "signed dry-run: dmg is signed with the SHA-1" "${OUT}" "codesign --force --sign ${HASH_A} --timestamp"
assert_has "signed dry-run: notarytool submit as json" "${OUT}" "notarytool submit"
assert_has "signed dry-run: json output" "${OUT}" "--output-format json"
assert_has "signed dry-run: notary profile" "${OUT}" "--keychain-profile no-such-profile --wait"
assert_has "signed dry-run: stapler" "${OUT}" "stapler staple"
assert_has "signed dry-run: Accepted is required" "${OUT}" "require status Accepted"
assert_has "signed dry-run: signature checks come before notarization" "$(sed -n '/Verifying the signatures/,/Notarizing/p' <<<"${OUT}")" "Authority Developer ID Application"
assert_lacks "signed dry-run never prints the team id (full identity name in use)" "${OUT}" "${FAKE_TEAM}"
assert_has "signed dry-run warns signed mode is untested" "${OUT}" "not been tested"
assert "signed dry-run creates nothing" test ! -e "${WORK}/signed-dry"
assert "signed dry-run does not contact Apple (no xcrun call)" test ! -e "${WORK}/xcrun.calls"

BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME}" \
  run_release --dry-run --skip-notarize --version 1.2.3 --out-dir "${WORK}/signed-dry"
[ "${RC}" -eq 0 ] && pass "signed --dry-run --skip-notarize exits 0" || fail "signed --dry-run --skip-notarize exits 0 (rc=${RC})" "${OUT}"
assert_lacks "--skip-notarize prints no notarytool submit" "${OUT}" "notarytool submit"
assert_lacks "no --build leaves CURRENT_PROJECT_VERSION alone" "${OUT}" "CURRENT_PROJECT_VERSION"

BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME}" \
  run_release --dry-run --skip-notarize --register-device --version 1.2.3 --out-dir "${WORK}/signed-dry"
[ "${RC}" -eq 0 ] && pass "signed --dry-run --register-device exits 0" || fail "signed --dry-run --register-device exits 0 (rc=${RC})" "${OUT}"
assert_has "--register-device lets the archive register this Mac" "${OUT}" "-allowProvisioningDeviceRegistration"
run_release --dry-run --unsigned --register-device --out-dir "${WORK}/dry"
assert_has "--register-device in unsigned mode warns" "${OUT}" "--register-device has no effect in unsigned mode"

BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME}" \
  run_release --dry-run --version 1.2.3 --out-dir "${WORK}/signed-dry"
assert_has "missing BUDDY_NOTARY_PROFILE is reported" "${OUT}" "BUDDY_NOTARY_PROFILE is not set"

run_release --build "x7"
[ "${RC}" -ne 0 ] && pass "invalid --build exits non-zero" || fail "invalid --build exits non-zero"

# the same format and file checks as the phone scripts (lib/common.sh), with the values masked in the messages
API_ENV=(BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME}" BUDDY_NOTARY_PROFILE="x")
env "${API_ENV[@]}" BUDDY_ASC_KEY_PATH="${WORK}/AuthKey.p8" BUDDY_ASC_KEY_ID="short" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" \
  "${RELEASE}" --dry-run --version 1.2.3 --out-dir "${WORK}/signed-fail" >"${WORK}/o.txt" 2>&1 && RC=0 || RC=$?
OUT="$(cat "${WORK}/o.txt")"
[ "${RC}" -ne 0 ] && pass "a malformed key id is rejected" || fail "a malformed key id is rejected"
assert_has "a malformed key id: message" "${OUT}" "10 character key id"
env "${API_ENV[@]}" BUDDY_ASC_KEY_PATH="${WORK}/AuthKey.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="issuer-uuid" \
  "${RELEASE}" --dry-run --version 1.2.3 --out-dir "${WORK}/signed-fail" >"${WORK}/o.txt" 2>&1 && RC=0 || RC=$?
OUT="$(cat "${WORK}/o.txt")"
[ "${RC}" -ne 0 ] && pass "a malformed issuer id is rejected" || fail "a malformed issuer id is rejected"
assert_has "a malformed issuer id: message" "${OUT}" "issuer id (a UUID)"
assert_lacks "a malformed issuer id is not printed back" "${OUT}" "issuer-uuid"
cp "${WORK}/AuthKey.p8" "${WORK}/AuthKey-open.p8"
chmod 644 "${WORK}/AuthKey-open.p8"
env "${API_ENV[@]}" BUDDY_ASC_KEY_PATH="${WORK}/AuthKey-open.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" \
  "${RELEASE}" --dry-run --version 1.2.3 --out-dir "${WORK}/signed-fail" >"${WORK}/o.txt" 2>&1 && RC=0 || RC=$?
OUT="$(cat "${WORK}/o.txt")"
[ "${RC}" -eq 0 ] && pass "a group/world readable key file only warns (dry-run exits 0)" || fail "a group/world readable key file only warns (rc=${RC})" "${OUT}"
assert_has "a group/world readable key file: warning" "${OUT}" "accessible to other users"
assert_lacks "the key file warning does not print the key path" "${OUT}" "AuthKey-open.p8"
env "${API_ENV[@]}" BUDDY_ASC_KEY_PATH="${WORK}/no-such-key.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" \
  "${RELEASE}" --version 1.2.3 --out-dir "${WORK}/signed-fail" >"${WORK}/o.txt" 2>&1 && RC=0 || RC=$?
OUT="$(cat "${WORK}/o.txt")"
[ "${RC}" -ne 0 ] && pass "a missing key file is rejected" || fail "a missing key file is rejected"
assert_has "a missing key file: message" "${OUT}" "BUDDY_ASC_KEY_PATH does not exist"
assert_lacks "a missing key file: the path is masked" "${OUT}" "no-such-key.p8"

# A real (not dry) signed run with fake xcodegen/xcodebuild that print their arguments: what a tool relays is masked too.
mkdir -p "${WORK}/fakebin2"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/fakebin2/xcodegen"
printf '#!/bin/sh\necho "xcodebuild saw: $@"\nexit 0\n' >"${WORK}/fakebin2/xcodebuild"
chmod +x "${WORK}/fakebin2/xcodegen" "${WORK}/fakebin2/xcodebuild"
PATH="${WORK}/fakebin2:${PATH}" env "${API_ENV[@]}" BUDDY_ASC_KEY_PATH="${WORK}/AuthKey.p8" BUDDY_ASC_KEY_ID="${FAKE_KEY_ID}" BUDDY_ASC_ISSUER_ID="${FAKE_ISSUER}" \
  "${RELEASE}" --skip-notarize --version 1.2.3 --out-dir "${WORK}/signed-real" >"${WORK}/o.txt" 2>&1 && RC=0 || RC=$?
OUT="$(cat "${WORK}/o.txt")"
[ "${RC}" -ne 0 ] && pass "a real signed run with a fake xcodebuild stops (no app was built)" || fail "a real signed run with a fake xcodebuild stops" "${OUT}"
assert_has "real run: the fake xcodebuild was called with the key flags" "${OUT}" "xcodebuild saw:"
assert_has "real run: relayed tool output carries the masked key id" "${OUT}" "-authenticationKeyID <BUDDY_ASC_KEY_ID>"
assert_lacks "real run never prints the key id" "${OUT}" "${FAKE_KEY_ID}"
assert_lacks "real run never prints the issuer id" "${OUT}" "${FAKE_ISSUER}"
assert_lacks "real run never prints the key path" "${OUT}" "AuthKey.p8"
assert_lacks "real run never prints the team id" "${OUT}" "${FAKE_TEAM}"

# ---- the archive entitlements file ----------------------------------------------------------------------------------

# The archive is development-signed: it must carry the development push environment (a development profile refuses
# production) and no container environment (the export sets Production). verify_signatures checks the exported values.
ARCH_ENT="${SCRIPT_DIR}/../Apps/BuddyMac/BuddyMac.cloud.entitlements"
assert "cloud entitlements are a valid plist" plutil -lint "${ARCH_ENT}"
assert "cloud entitlements: aps-environment development" bash -c '/usr/libexec/PlistBuddy -c "Print :com.apple.developer.aps-environment" "$1" | grep -qx development' _ "${ARCH_ENT}"
assert "cloud entitlements: no container environment (set at export)" bash -c '! /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-environment" "$1" >/dev/null 2>&1' _ "${ARCH_ENT}"
assert "cloud entitlements carry no team id (it comes from the profile)" bash -c '! /usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" "$1" >/dev/null 2>&1 && ! /usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$1" >/dev/null 2>&1' _ "${ARCH_ENT}"
assert "no release entitlements file is left behind" bash -c '[ ! -e "$1" ]' _ "${SCRIPT_DIR}/../Apps/BuddyMac/BuddyMac.release.entitlements"
assert "the default entitlements stay empty (no iCloud keys)" bash -c '! grep -q "icloud" "$1"' _ "${SCRIPT_DIR}/../Apps/BuddyMac/BuddyMac.entitlements"

# ---- entitlement_value_is is key-specific (ad-hoc signed copies of /usr/bin/true, never launched) -------------------

# Load the real functions from release.sh (entitlements_of and entitlement_value_is), not a copy of their logic.
eval "$(sed -n '/^entitlements_of()/,/^team_of()/p' "${RELEASE}" | sed '$d')"
sign_with() { # sign_with <binary-name> <key> <value> [<key> <value>]...  (a throwaway ad-hoc signed copy of /usr/bin/true)
  local bin="${WORK}/$1" plist="${WORK}/$1.plist"
  shift
  cp /usr/bin/true "${bin}"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
    while [ $# -ge 2 ]; do
      printf '<key>%s</key><string>%s</string>' "$1" "$2"
      shift 2
    done
    printf '</dict></plist>\n'
  } >"${plist}"
  codesign --force --sign - --entitlements "${plist}" "${bin}" >/dev/null 2>&1
}
K_ENV="com.apple.developer.icloud-container-environment"
K_APS="com.apple.developer.aps-environment"
sign_with ent-good "${K_ENV}" Production "${K_APS}" production
sign_with ent-swapped "${K_ENV}" production "${K_APS}" Production
sign_with ent-onlyother "com.example.other" production
if entitlement_value_is "${WORK}/ent-good" "${K_ENV}" "Production" && entitlement_value_is "${WORK}/ent-good" "${K_APS}" "production"; then
  pass "entitlement_value_is: correct values pass"
else
  fail "entitlement_value_is: correct values pass"
fi
if entitlement_value_is "${WORK}/ent-swapped" "${K_ENV}" "Production" || entitlement_value_is "${WORK}/ent-swapped" "${K_APS}" "production"; then
  fail "entitlement_value_is: wrong case or swapped values must fail"
else
  pass "entitlement_value_is: wrong case or swapped values fail"
fi
if entitlement_value_is "${WORK}/ent-onlyother" "${K_APS}" "production"; then
  fail "entitlement_value_is: another key holding the value must not pass"
else
  pass "entitlement_value_is: another key holding the value does not pass (key-specific)"
fi

# ---- bundle checks: no Mach-O in Resources, every Mach-O verifies (fake bundles; the real functions from release.sh) -----

eval "$(sed -n '/^macho_files()/,/^# end of bundle helpers/p' "${RELEASE}")"
mk_fake_app() { # mk_fake_app <name>: a bundle skeleton with an ad-hoc signed Mach-O main executable and helper, nothing else
  local app="${WORK}/$1.app"
  mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources/sounds"
  cp /usr/bin/true "${app}/Contents/MacOS/Fake"
  cp /usr/bin/true "${app}/Contents/MacOS/buddy-hook"
  codesign --force --sign - "${app}/Contents/MacOS/Fake" >/dev/null 2>&1
  codesign --force --sign - "${app}/Contents/MacOS/buddy-hook" >/dev/null 2>&1
  printf 'not a binary' >"${app}/Contents/Resources/sounds/SOURCES.md"
  printf 'RIFF' >"${app}/Contents/Resources/sounds/open.wav"
}
mk_fake_app clean
assert "no_macho_in_resources: a bundle with only resources passes" no_macho_in_resources "${WORK}/clean.app"
assert "all_macho_verify: signed Mach-O files pass" all_macho_verify "${WORK}/clean.app"
mk_fake_app stray
cp "${WORK}/stray.app/Contents/MacOS/buddy-hook" "${WORK}/stray.app/Contents/Resources/buddy-hook"
assert "no_macho_in_resources: a buddy-hook copy in Resources fails" not no_macho_in_resources "${WORK}/stray.app"
assert_has "macho_files names the stray copy" "$(macho_files "${WORK}/stray.app/Contents/Resources")" "Contents/Resources/buddy-hook"
mk_fake_app deep
mkdir -p "${WORK}/deep.app/Contents/Resources/tools/x"
cp /usr/bin/true "${WORK}/deep.app/Contents/Resources/tools/x/helper"
assert "no_macho_in_resources: a Mach-O in a Resources subfolder fails" not no_macho_in_resources "${WORK}/deep.app"
mk_fake_app unsignedmacho
codesign --remove-signature "${WORK}/unsignedmacho.app/Contents/MacOS/buddy-hook" >/dev/null 2>&1
assert "all_macho_verify: an unsigned Mach-O fails" not all_macho_verify "${WORK}/unsignedmacho.app"
mk_fake_app tampered
printf 'x' >>"${WORK}/tampered.app/Contents/MacOS/buddy-hook"
assert "all_macho_verify: a modified signed Mach-O fails" not all_macho_verify "${WORK}/tampered.app"
mkdir -p "${WORK}/empty.app/Contents/Resources"
assert "all_macho_verify: a bundle with no Mach-O at all fails" not all_macho_verify "${WORK}/empty.app"

# the provisioning profile check (signed mode): present and non-empty passes, missing or empty fails
mk_fake_app withprofile
printf 'profile' >"${WORK}/withprofile.app/Contents/embedded.provisionprofile"
assert "has_provisioning_profile: a bundle with the profile passes" has_provisioning_profile "${WORK}/withprofile.app"
assert "has_provisioning_profile: a bundle without the profile fails" not has_provisioning_profile "${WORK}/clean.app"
: >"${WORK}/withprofile.app/Contents/embedded.provisionprofile"
assert "has_provisioning_profile: an empty profile file fails" not has_provisioning_profile "${WORK}/withprofile.app"
# verify_signatures runs the check in signed mode only (a missing profile fails the run before anything goes to Apple)
SIGNED_BLOCK="$(sed -n '/^verify_signatures()/,/^}/p' "${RELEASE}" | sed -n '/if \[ "\${MODE}" = "signed" \]; then/,$p')"
assert_has "verify_signatures: the signed block checks the provisioning profile" "${SIGNED_BLOCK}" 'has_provisioning_profile "${APP_PATH}"'
assert_lacks "verify_signatures: the profile check is not in the both-modes part" "$(sed -n '/^verify_signatures()/,/if \[ "\${MODE}" = "signed" \]; then/p' "${RELEASE}")" "has_provisioning_profile"
assert_has "signed dry-run: the plan lists the provisioning profile" "$(BUDDY_TEST_IDENTITIES_FILE="${WORK}/ids-one.txt" BUDDY_TEAM_ID="${FAKE_TEAM}" BUDDY_SIGN_IDENTITY="${FULL_NAME}" BUDDY_NOTARY_PROFILE=x "${RELEASE}" --dry-run --version 1.2.3 --out-dir "${WORK}/signed-dry" 2>&1)" "embedded.provisionprofile"

# ---- the app's sounds (a CC0 set per character, listed in SOURCES.md) ------------------------------------------------

REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." >/dev/null && pwd -P)"
SOUNDS="${REPO_ROOT}/Apps/BuddyMac/Resources/sounds"
SOURCES="${SOUNDS}/SOURCES.md"
# The raw value of every SoundCue case (`case a, b` lines; `case switchSession = "switch"` gives "switch").
SOUND_CUES="$(sed -n '/^enum SoundCue/,/^}/p' "${REPO_ROOT}/Apps/BuddyMac/Sound/SoundTrigger.swift" \
  | sed -n 's/^ *case \(.*\)$/\1/p' | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e 's/^[A-Za-z]* = "\(.*\)"$/\1/')"
assert "SoundCue lists 26 cues" test "$(printf '%s\n' "${SOUND_CUES}" | wc -l | tr -d ' ')" = "26"
assert "SOURCES.md exists" test -f "${SOURCES}"
assert "SOURCES.md names the licence and the fetch date" grep -q "fetched on 20[0-9-]*" "${SOURCES}"
while IFS= read -r file; do
  rel="${file#"${SOUNDS}"/}"
  assert "sounds/${rel} is listed in SOURCES.md on a line containing CC0" bash -c \
    'grep -F -- "$1" "$2" | grep -q "CC0"' _ "${rel}" "${SOURCES}"
done < <(find "${SOUNDS}" -type f ! -name SOURCES.md | sort)
for name in ${SOUND_CUES}; do
  assert "sounds/block/${name}.wav exists for the ${name} cue" test -f "${SOUNDS}/block/${name}.wav"
  info="$(afinfo "${SOUNDS}/block/${name}.wav" 2>/dev/null || true)"
  assert_has "${name}.wav is 16-bit PCM" "${info}" "Int16"
  seconds="$(sed -n 's/^estimated duration: \([0-9.]*\).*/\1/p' <<<"${info}")"
  assert "${name}.wav is shorter than 1.5 s (${seconds:-?} s)" awk -v s="${seconds:-9}" 'BEGIN { exit !(s > 0 && s < 1.5) }'
done

# ---- unsigned end to end -------------------------------------------------------------------------------------------

if [ "${SKIP_BUILD}" -eq 1 ]; then
  printf 'skip the unsigned end-to-end build (--skip-build)\n'
else
  VERSION="9.8.7"
  DIST="${WORK}/dist"
  APP="${DIST}/build/Build/Products/Release/BuddyMac.app"
  DMG="${DIST}/Buddy-${VERSION}.dmg"

  printf '... unsigned end-to-end build (a few minutes)\n'
  set +e
  OUT="$(env -u BUDDY_TEAM_ID -u BUDDY_SIGN_IDENTITY -u BUDDY_NOTARY_PROFILE "${RELEASE}" --version "${VERSION}" --build 42 --out-dir "${DIST}" 2>&1)"
  RC=$?
  set -e
  [ "${RC}" -eq 0 ] && pass "unsigned release.sh exits 0" || fail "unsigned release.sh exits 0 (rc=${RC})" "$(tail -30 <<<"${OUT}")"
  assert_has "prints that the dmg is not notarized" "${OUT}" "NOT NOTARIZED"
  assert_has "prints the Open Anyway hint (macOS 15)" "${OUT}" "Open Anyway"
  assert_has "names System Settings > Privacy & Security" "${OUT}" "System Settings > Privacy & Security"
  assert_lacks "does not print the outdated right-click hint" "${OUT}" "right-click"
  assert_has "prints the xattr hint" "${OUT}" "xattr -dr com.apple.quarantine /Applications/BuddyMac.app"
  assert_lacks "self-verification reported no failure" "${OUT}" "FAIL"

  assert "dmg exists" test -f "${DMG}"
  assert "sha256 file exists" test -f "${DMG}.sha256"
  assert "sha256 file matches (shasum -c)" bash -c 'cd "$1" && shasum -a 256 -c "$2"' _ "${DIST}" "Buddy-${VERSION}.dmg.sha256"
  assert "sha256 file names the dmg" grep -Fq "Buddy-${VERSION}.dmg" "${DMG}.sha256"

  fmt="$(hdiutil imageinfo "${DMG}" 2>/dev/null | sed -n 's/^Format: //p' | head -n 1 || true)"
  [ "${fmt}" = "UDZO" ] && pass "dmg is compressed UDZO" || fail "dmg is compressed UDZO (got '${fmt}')"

  assert "app codesign --verify --deep --strict" codesign --verify --deep --strict "${APP}"
  assert "embedded buddy-hook is executable" test -x "${APP}/Contents/MacOS/buddy-hook"
  assert "the real app has no Mach-O in Contents/Resources (no second buddy-hook)" no_macho_in_resources "${APP}"
  assert "the real app: buddy-hook exists only in Contents/MacOS" test "$(find "${APP}" -name buddy-hook | wc -l | tr -d ' ')" = "1"
  assert "the real app: every Mach-O passes codesign --verify --strict" all_macho_verify "${APP}"
  assert_has "release.sh reported the Resources check" "${OUT}" "no Mach-O in Contents/Resources"
  assert "app build number is 42" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist")" = "42"
  assert "app version is ${VERSION}" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")" = "${VERSION}"

  assert "app carries the placeholder icon (AppIcon.icns)" test -f "${APP}/Contents/Resources/AppIcon.icns"
  assert "app Info.plist names the icon (CFBundleIconName AppIcon)" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "${APP}/Contents/Info.plist")" = "AppIcon"
  assert "app carries sounds/SOURCES.md, identical to the committed file" cmp -s "${APP}/Contents/Resources/sounds/SOURCES.md" "${SOURCES}"
  assert "app carries no THIRD-PARTY-NOTICES.md" test ! -e "${APP}/Contents/Resources/THIRD-PARTY-NOTICES.md"
  for name in ${SOUND_CUES}; do
    assert "app carries sounds/block/${name}.wav, identical to the committed file" cmp -s "${APP}/Contents/Resources/sounds/block/${name}.wav" "${SOUNDS}/block/${name}.wav"
  done

  set +e
  names_out="$("${CHECK_NAMES}" "${APP}" 2>&1)"
  names_rc=$?
  set -e
  [ "${names_rc}" -eq 0 ] && pass "check-names.sh: no outside names in the built app" \
    || fail "check-names.sh: no outside names in the built app (rc=${names_rc})" "${names_out}"

  sig="$(codesign -dvv "${APP}" 2>&1 || true)"
  assert_has "app is ad-hoc signed" "${sig}" "Signature=adhoc"
  assert_lacks "app has no hardened runtime" "${sig}" "(runtime)"
  ent="$(codesign -d --entitlements - "${APP}" 2>&1 || true)"
  assert_lacks "app has no iCloud entitlements" "${ent}" "icloud"
  hook_sig="$(codesign -dvv "${APP}/Contents/MacOS/buddy-hook" 2>&1 || true)"
  assert_has "buddy-hook is ad-hoc signed" "${hook_sig}" "Signature=adhoc"

  # Mount the dmg ourselves, at a temp mount point, read-only, and always detach.
  mkdir -p "${MNT}"
  if hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${MNT}" "${DMG}" >/dev/null 2>&1; then
    assert "dmg holds BuddyMac.app" test -d "${MNT}/BuddyMac.app"
    assert "dmg holds the Applications link" test "$(readlink "${MNT}/Applications")" = "/Applications"
    assert "dmg's embedded buddy-hook is executable" test -x "${MNT}/BuddyMac.app/Contents/MacOS/buddy-hook"
    hdiutil detach "${MNT}" -quiet >/dev/null 2>&1 || hdiutil detach "${MNT}" -force -quiet >/dev/null 2>&1 || true
  else
    fail "dmg mounts"
  fi
  assert "test mount point is detached" bash -c '! mount | grep -Fq -- "$1"' _ "${MNT}"
  assert "release.sh left nothing mounted" bash -c '! hdiutil info | grep -Fq -- "buddy-release."'
  assert "dmg did not change while mounted read-only" bash -c 'cd "$1" && shasum -a 256 -c "$2"' _ "${DIST}" "Buddy-${VERSION}.dmg.sha256"
fi

printf '\n%d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]
