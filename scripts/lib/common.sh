# shellcheck shell=bash
#
# Shared helpers for scripts/release.sh, scripts/phone-signed-build.sh and scripts/testflight.sh. Sourced, never executed.
#
# The sourcing script must set DRY_RUN (0 or 1) and define usage(). Bash 3.2 compatible.
#
# Secrets never appear in output: the Team ID, the App Store Connect key id, issuer id and key path are registered with
# add_mask, and everything printed (messages, commands, relayed tool output) goes through the mask.

MASK_VALUES=()
MASK_LABELS=()
MASK_FLAGS=()
MASK_SED=()
MASK_DIRTY=1

# add_mask <value> <label> [I]   (I: match case-insensitively; used for the Team ID)
add_mask() {
  [ -n "$1" ] || return 0
  MASK_VALUES+=("$1")
  MASK_LABELS+=("$2")
  MASK_FLAGS+=("${3:-}")
  MASK_DIRTY=1
}

# Build the sed script once per change of the mask list (the values are escaped for a basic regular expression).
# Longer values come first, so a short secret (the Team ID) inside a longer one (a key path) cannot leave part of the
# longer one visible.
mask_prepare() {
  [ "${MASK_DIRTY}" -eq 1 ] || return 0
  MASK_SED=()
  local done_list=" " n="${#MASK_VALUES[@]}" round=0 i best best_len esc
  while [ "${round}" -lt "${n}" ]; do
    best=-1
    best_len=-1
    i=0
    while [ "${i}" -lt "${n}" ]; do
      case "${done_list}" in
        *" ${i} "*) ;;
        *)
          if [ "${#MASK_VALUES[$i]}" -gt "${best_len}" ]; then
            best="${i}"
            best_len="${#MASK_VALUES[$i]}"
          fi
          ;;
      esac
      i=$((i + 1))
    done
    done_list="${done_list}${best} "
    esc="$(printf '%s' "${MASK_VALUES[$best]}" | sed 's/[][\\.*^$/]/\\&/g')"
    MASK_SED+=(-e "s/${esc}/${MASK_LABELS[$best]}/g${MASK_FLAGS[$best]}")
    round=$((round + 1))
  done
  MASK_DIRTY=0
}

# Filter for tool output: masks every registered secret in a stream.
mask_stream() {
  mask_prepare
  if [ "${#MASK_SED[@]}" -eq 0 ]; then
    cat
  else
    sed "${MASK_SED[@]}"
  fi
}

mask() {
  local s
  s="$(printf '%s' "$*" | mask_stream)"
  printf '%s' "${s}"
}

info() { printf '==> %s\n' "$(mask "$*")"; }
warn() { printf 'warning: %s\n' "$(mask "$*")" >&2; }
die() {
  printf 'error: %s\n' "$(mask "$*")" >&2
  exit 1
}
usage_error() {
  printf 'error: %s\n\n' "$(mask "$*")" >&2
  usage >&2
  exit 2
}

# Print a command with the secrets masked, and run it unless --dry-run. Tool output is masked too.
show_cmd() {
  local out="" a
  for a in "$@"; do
    a="$(mask "${a}")"
    case "${a}" in
      "" | *[!A-Za-z0-9_./:=,@%+-]*) out+=" '${a}'" ;; # quote what a shell would need quoted (for reading only)
      *) out+=" ${a}" ;;
    esac
  done
  printf '    $%s\n' "${out}"
}
run() {
  show_cmd "$@"
  if [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi
  "$@" 2>&1 | mask_stream
}

# A missing prerequisite is fatal, except under --dry-run, which still prints the commands (as a warning).
preflight_fail() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    warn "(dry-run, would fail) $*"
  else
    die "$*"
  fi
}

# ---- shared checks ----------------------------------------------------------------------------------------------

# BUDDY_TEAM_ID is required and must look like a Team ID; it is registered for masking right away.
require_team_id() {
  TEAM_ID="${BUDDY_TEAM_ID:-}"
  if [ -z "${TEAM_ID}" ]; then
    die "BUDDY_TEAM_ID is not set. Export your Apple Developer Team ID (10 characters, Apple Developer portal > Membership), for example: export BUDDY_TEAM_ID=<your team id>. It is never stored in a file."
  fi
  printf '%s' "${TEAM_ID}" | grep -Eq '^[A-Za-z0-9]{10}$' || die "BUDDY_TEAM_ID must be a 10 character Apple Team ID (letters and digits)."
  add_mask "${TEAM_ID}" "<BUDDY_TEAM_ID>" I
}

# The optional or required App Store Connect API key. Sets ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID.
#   check_asc_key required   all three variables must be set
#   check_asc_key optional   all three or none
# The key id, issuer id and the key path are masked in all output. The key file itself is never read or printed.
ASC_KEY_PATH=""
ASC_KEY_ID=""
ASC_ISSUER_ID=""
check_asc_key() {
  local need="$1"
  ASC_KEY_PATH="${BUDDY_ASC_KEY_PATH:-}"
  ASC_KEY_ID="${BUDDY_ASC_KEY_ID:-}"
  ASC_ISSUER_ID="${BUDDY_ASC_ISSUER_ID:-}"
  add_mask "${ASC_KEY_PATH}" "<BUDDY_ASC_KEY_PATH>"
  add_mask "${ASC_ISSUER_ID}" "<BUDDY_ASC_ISSUER_ID>"
  add_mask "${ASC_KEY_ID}" "<BUDDY_ASC_KEY_ID>"

  if [ -z "${ASC_KEY_PATH}${ASC_KEY_ID}${ASC_ISSUER_ID}" ]; then
    if [ "${need}" = "required" ]; then
      die "The App Store Connect API key is not set. Export BUDDY_ASC_KEY_PATH (the AuthKey_<id>.p8 file), BUDDY_ASC_KEY_ID and BUDDY_ASC_ISSUER_ID (App Store Connect > Users and Access > Integrations > App Store Connect API)."
    fi
    return 0
  fi
  if [ -z "${ASC_KEY_PATH}" ] || [ -z "${ASC_KEY_ID}" ] || [ -z "${ASC_ISSUER_ID}" ]; then
    die "Set all of BUDDY_ASC_KEY_PATH, BUDDY_ASC_KEY_ID and BUDDY_ASC_ISSUER_ID, or none of them."
  fi
  printf '%s' "${ASC_KEY_ID}" | grep -Eq '^[A-Za-z0-9]{10}$' || die "BUDDY_ASC_KEY_ID must be the 10 character key id of the App Store Connect API key."
  printf '%s' "${ASC_ISSUER_ID}" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || die "BUDDY_ASC_ISSUER_ID must be the issuer id (a UUID) shown in App Store Connect."
  if [ ! -e "${ASC_KEY_PATH}" ]; then
    preflight_fail "BUDDY_ASC_KEY_PATH does not exist: ${ASC_KEY_PATH}"
  elif [ ! -f "${ASC_KEY_PATH}" ]; then
    preflight_fail "BUDDY_ASC_KEY_PATH is not a file: ${ASC_KEY_PATH}"
  elif [ ! -r "${ASC_KEY_PATH}" ]; then
    preflight_fail "BUDDY_ASC_KEY_PATH is not readable by this user: ${ASC_KEY_PATH}"
  elif [ ! -s "${ASC_KEY_PATH}" ]; then
    preflight_fail "BUDDY_ASC_KEY_PATH is an empty file: ${ASC_KEY_PATH}"
  else
    local mode
    mode="$(stat -f %Lp "${ASC_KEY_PATH}" 2>/dev/null || true)"
    # Only the group and other bits matter: owner-only modes (400, 500, 600, 700) are fine.
    case "${mode}" in
      "" | *00 | 0) ;;
      *) warn "The API key file is accessible to other users (mode ${mode}). Restrict it: chmod 600 <the key file>." ;;
    esac
  fi
}

# Authentication flags for xcodebuild, one per line (empty when there is no API key).
auth_args() {
  if [ -n "${ASC_KEY_PATH}" ]; then
    printf '%s\n' -authenticationKeyPath "${ASC_KEY_PATH}" -authenticationKeyID "${ASC_KEY_ID}" -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
  fi
}

# Fill the array named $1 with the authentication flags (bash 3.2 has no namerefs, so it is set through eval).
load_auth_args() {
  local line
  eval "$1=()"
  while IFS= read -r line; do
    [ -z "${line}" ] || eval "$1+=(\"\${line}\")"
  done < <(auth_args)
}

# Tools every script here needs. xcodebuild and xcodegen are checked by name only (nothing is run).
check_build_tools() {
  command -v xcodegen >/dev/null 2>&1 || preflight_fail "xcodegen not found. Install it (brew install xcodegen) and retry."
  command -v xcodebuild >/dev/null 2>&1 || preflight_fail "xcodebuild not found. Install Xcode and select it with xcode-select."
  command -v xcrun >/dev/null 2>&1 || preflight_fail "xcrun not found. Install Xcode and select it with xcode-select."
  command -v plutil >/dev/null 2>&1 || preflight_fail "plutil not found (this script needs macOS)."
  command -v codesign >/dev/null 2>&1 || preflight_fail "codesign not found (this script needs macOS)."
}

# Version and build number checks shared by both scripts. MARKETING_VERSION is read from Apps/project.yml by default.
read_marketing_version() {
  sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "$1" | head -n 1
}
check_version() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || die "Invalid version '$1': expected X.Y.Z (digits and dots)."
}
check_build_number() {
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "Invalid build number '$1': expected a number like 7 (up to three dot-separated integers)."
}

# Entitlements of a signed bundle or binary. Key-specific: plutil extracts that one key (dots in the key are escaped,
# they separate key path components), whatever the layout of the XML codesign prints.
entitlements_of() { codesign -d --entitlements :- "$1" 2>/dev/null; }
# entitlement_raw <path> <key>: the value of one key as plutil prints it (a string, or true/false), empty if absent.
entitlement_raw() {
  local key="${2//./\\.}"
  entitlements_of "$1" | plutil -extract "${key}" raw -o - - 2>/dev/null || true
}
# True when the entitlement key $2 of $1 has exactly the value $3.
entitlement_value_is() { [ "$(entitlement_raw "$1" "$2")" = "$3" ]; }
# True when the key $2 exists at all (any type, so also the array-valued iCloud keys).
entitlement_present() {
  local key="${2//./\\.}"
  entitlements_of "$1" | plutil -extract "${key}" xml1 -o - - >/dev/null 2>&1
}

# check "<description>" <command...>   and   check_not (passes when the command fails). Sets check_failed=1.
check_failed=0
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '    ok   %s\n' "$(mask "${desc}")"
  else
    printf '    FAIL %s\n' "$(mask "${desc}")" >&2
    check_failed=1
  fi
}
check_not() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '    FAIL %s\n' "$(mask "${desc}")" >&2
    check_failed=1
  else
    printf '    ok   %s\n' "$(mask "${desc}")"
  fi
}
