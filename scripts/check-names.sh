#!/usr/bin/env bash
#
# Checks that no outside product or character name is left in Buddy. Case-insensitive.
#
# - Tracked files (`git ls-files`): every path, and every file's contents (text line by line, anything else byte by byte).
# - With an app: every file name in the bundle; the raw bytes of every file in it (resources, Info.plist files,
#   executables, nested bundles, frameworks and plug-ins alike); every Info.plist again as XML; and the constants that
#   every Mach-O file builds in its code (arm64 mov/movk and x86_64 mov immediates, which is where Swift keeps a short
#   string literal of up to 15 bytes instead of in the data, so a byte search alone cannot see it).
#
# Lines that contain the repo folder's own name are ignored while that name itself matches (the folder is to be renamed);
# the script says so when it does. This file holds the patterns and is not searched. Not searched: UTF-16 and compressed
# text (binary .strings files, compressed PNG text chunks).
#
# Read-only: it lists matches and changes nothing.
#
# Usage: scripts/check-names.sh [path/to/BuddyMac.app]   (exit 0: no matches, 1: matches listed, 2: usage error)

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
SELF="scripts/check-names.sh"

APP=""
case "$#" in
  0) ;;
  1)
    APP="$1"
    if [ ! -d "${APP}" ]; then
      echo "check-names: no app at ${APP}" >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: $0 [path/to/BuddyMac.app]" >&2
    exit 2
    ;;
esac

# Text is searched as UTF-8, so that the accented pattern matches whatever the caller's locale is. `raillé` and `raille`
# count only when no letter comes right before them, so the English word "braille" is not a match.
export LC_ALL=en_US.UTF-8
PATTERN='coucou|mochi|notchbuddy|louis|(^|[^[:alpha:]])raill(é|e)'
# Raw bytes are searched in the C locale (any byte is a character there); -i then folds ASCII only, hence the É.
BYTE_PATTERN='coucou|mochi|notchbuddy|louis|(^|[^[:alpha:]])raill(é|É|e)'

FOLDER="$(basename "${REPO_ROOT}")"
IGNORE=""
if grep -Eiq -- "${PATTERN}" <<<"${FOLDER}"; then
  IGNORE="${FOLDER}"
  echo "check-names: ignoring lines that contain the repo folder name (${FOLDER}) until the folder is renamed"
fi

MATCHES="$(mktemp "${TMPDIR:-/tmp}/buddy-check-names.XXXXXX")"
trap 'rm -f "${MATCHES}"' EXIT

# keep: stdin lines matching the pattern, minus those that contain the ignored folder name.
keep() {
  if [ -n "${IGNORE}" ]; then
    grep -Ei -- "${PATTERN}" | grep -Fiv -- "${IGNORE}" || true
  else
    grep -Ei -- "${PATTERN}" || true
  fi
}

# keep_bytes: the same for raw bytes (C locale), printed with every unprintable byte as a dot.
keep_bytes() {
  {
    if [ -n "${IGNORE}" ]; then
      LC_ALL=C grep -Eai -- "${BYTE_PATTERN}" | LC_ALL=C grep -Faiv -- "${IGNORE}" || true
    else
      LC_ALL=C grep -Eai -- "${BYTE_PATTERN}" || true
    fi
  } | LC_ALL=C tr -c '[:print:]\n' '.'
}

# scan_bytes <label> <file>: every match in the file's raw bytes, with up to 40 bytes on each side.
scan_bytes() {
  local label="$1" file="$2"
  LC_ALL=C grep -aoiE -- ".{0,40}(${BYTE_PATTERN}).{0,40}" "${file}" 2>/dev/null | keep_bytes \
    | sed "s|^|${label} (bytes): |" >>"${MATCHES}" || true
}

# search_file <label> <file>: text files line by line (with line numbers), anything else byte by byte.
search_file() {
  local label="$1" file="$2"
  if [ ! -s "${file}" ]; then
    return 0
  fi
  if grep -Iq . "${file}" 2>/dev/null; then
    grep -n "" "${file}" | keep | sed "s|^|${label}:|" >>"${MATCHES}"
  else
    scan_bytes "${label}" "${file}"
  fi
}

# immediates <macho>: the constants the code builds in registers, decoded as bytes (low byte first). arm64: a `mov`
# followed by `movk ..., lsl #n` to the same register fills it 16 bits at a time; x86_64: one `movabsq`/`movq`/`movl`
# with a `$0x...` value (or the `## imm = 0x...` otool notes for a negative one). Only bytes that can be text are kept,
# and any other byte ends the value. A value that fills all 8 bytes runs on into the next one, so a literal split over
# two registers (up to 15 bytes) reads as one string; a shorter value ends the line.
immediates() {
  local file="$1" arch
  for arch in $(lipo -archs "${file}" 2>/dev/null || true); do
    otool -arch "${arch}" -tv "${file}" 2>/dev/null | LC_ALL=C awk -v arch="${arch}" '
      function hexbyte(h, k,    hi, lo) {  # byte k (0 = lowest) of the 16-digit hex string h
        hi = index("0123456789abcdef", substr(h, 16 - 2 * k - 1, 1)) - 1
        lo = index("0123456789abcdef", substr(h, 16 - 2 * k, 1)) - 1
        return hi * 16 + lo
      }
      function pad(h) { h = tolower(h); while (length(h) < 16) h = "0" h; return h }
      function emit(r,    k, b, s) {  # the text of register r, joined to the previous value when that one was full
        s = ""
        for (k = 0; k < 8; k++) {
          b = bytes[r, k] + 0
          if (b < 32 || b == 127) break
          s = s sprintf("%c", b)
        }
        line = line s
        if (length(s) < 8) {
          if (length(line) >= 4) print line
          line = ""
        }
      }
      function done() { if (cur != "") { emit(cur); cur = "" } }
      {
        split($0, f, "\t")
        op = f[2]; args = f[3]
        if (arch != "x86_64" && (op == "mov" || op == "movk") && match(args, /^[xw][0-9]+, #0x[0-9a-f]+/)) {
          r = substr(args, 2, index(args, ",") - 2) + 0
          h = substr(args, index(args, "#0x") + 3)
          sub(/[^0-9a-f].*$/, "", h)
          h = pad(h)
          if (op == "mov") {
            done()
            for (k = 0; k < 8; k++) bytes[r, k] = hexbyte(h, k)
          } else {
            if (cur != "" && cur != r) done()
            sh = 0
            if (match(args, /lsl #[0-9]+/)) sh = substr(args, RSTART + 5, RLENGTH - 5) / 8
            bytes[r, sh] = hexbyte(h, 0); bytes[r, sh + 1] = hexbyte(h, 1)
          }
          cur = r
          next
        }
        if (arch == "x86_64" && (op == "movabsq" || op == "movq" || op == "movl") && match(args, /^\$-?0x[0-9a-f]+, %/)) {
          done()
          if (match(args, /imm = 0x[0-9A-Fa-f]+/)) h = substr(args, RSTART + 8, RLENGTH - 8)
          else if (substr(args, 2, 1) == "-") next
          else h = substr(args, 4, index(args, ",") - 4)
          h = pad(h)
          for (k = 0; k < 8; k++) bytes["x", k] = (op == "movl" && k >= 4) ? 0 : hexbyte(h, k)
          emit("x")
          next
        }
        done()
      }
      END { done(); if (length(line) >= 4) print line }
    ' || true
  done
}

# ---- tracked files --------------------------------------------------------------------------------------------------

while IFS= read -r path; do
  [ "${path}" = "${SELF}" ] && continue
  printf '%s\n' "${path}" | keep | sed 's|^|file name: |' >>"${MATCHES}"
  [ -f "${REPO_ROOT}/${path}" ] || continue
  search_file "${path}" "${REPO_ROOT}/${path}"
done < <(git -C "${REPO_ROOT}" ls-files)

# ---- the app --------------------------------------------------------------------------------------------------------

if [ -n "${APP}" ]; then
  APP="$(unset CDPATH; cd -P "${APP}" >/dev/null && pwd -P)"
  # Every file name in the bundle.
  (cd "${APP}" && find . -print) | keep | sed "s|^\.|app file name: |" >>"${MATCHES}"
  # The raw bytes of every file, wherever it is in the bundle.
  while IFS= read -r file; do
    scan_bytes "app ${file#"${APP}"/}" "${file}"
  done < <(find "${APP}" -type f | sort)
  # Info.plist files, read as XML (they are usually binary plists).
  while IFS= read -r plist; do
    plutil -convert xml1 -o - "${plist}" 2>/dev/null | grep -n "" | keep \
      | sed "s|^|app ${plist#"${APP}"/}:|" >>"${MATCHES}"
  done < <(find "${APP}" -name Info.plist -type f | sort)
  # Constants built in the code of every Mach-O file (short Swift string literals live there).
  while IFS= read -r file; do
    if file -b "${file}" | grep -q "Mach-O"; then
      immediates "${file}" | keep_bytes | sed "s|^|app ${file#"${APP}"/} (code constants): |" >>"${MATCHES}"
    fi
  done < <(find "${APP}" -type f | sort)
fi

if [ -s "${MATCHES}" ]; then
  echo "check-names: FAIL, $(wc -l <"${MATCHES}" | tr -d ' ') matching lines:" >&2
  cat "${MATCHES}" >&2
  exit 1
fi
if [ -n "${APP}" ]; then
  echo "check-names: no matches in the tracked files or in ${APP}"
else
  echo "check-names: no matches in the tracked files"
fi
