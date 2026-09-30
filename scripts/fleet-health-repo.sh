#!/usr/bin/env bash
# Probe one npm checkout and print a fleet-health table row.
#
# Canonical scripts, shared with .github/workflows/ci.yml:
#   lint
#   check       type-check. "typecheck" is accepted when "check" is absent.
#   build
#   test
# A missing script is a skip (—), not a failure. A script that exits non-zero
# fails the probe (❌).
#
#   scripts/fleet-health-repo.sh --name REPO DIR
#
# Prints one markdown row on stdout. npm output is kept on failure (last 40
# lines on stderr). Exit 0 when install and every present script succeed;
# exit 1 otherwise.
#
# GitHub Actions runs workflow steps with `bash -e`. A non-zero status in that
# mode aborts the step immediately, which used to drop the row whenever a
# script was missing or failed. Errexit is turned off here so the row is
# always printed. Run this file; do not source it.
set -uo pipefail
set +e

NAME=""
DIR=""

usage() {
  echo "Usage: fleet-health-repo.sh --name REPO DIR" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$DIR" ]]; then
        echo "Unexpected argument: $1" >&2
        usage
        exit 2
      fi
      DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "$NAME" || -z "$DIR" ]]; then
  usage
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

icon() {
  case "$1" in
    0) printf '✅' ;;
    1) printf '❌' ;;
    *) printf '—' ;;
  esac
}

pkg="$DIR/package.json"

has_script() {
  local script_name="$1"
  [[ -f "$pkg" ]] || return 1
  jq -e --arg s "$script_name" '.scripts[$s] // empty' "$pkg" >/dev/null 2>&1
}

# Print the first of the given script names that package.json defines.
resolve_script() {
  local script_name
  for script_name in "$@"; do
    if has_script "$script_name"; then
      printf '%s\n' "$script_name"
      return 0
    fi
  done
  return 2
}

# Run npm in DIR. On failure, show the tail of its output.
run_npm() {
  local log rc
  log="$(mktemp)"
  ( cd "$DIR" && npm "$@" ) >"$log" 2>&1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "---- npm $* failed (exit $rc) ----" >&2
    tail -n 40 "$log" >&2
  fi
  rm -f "$log"
  return "$rc"
}

# 0 pass, 1 fail, 2 absent. $1 is the canonical name; the rest are fallbacks.
run_column() {
  local resolved
  if ! resolved="$(resolve_script "$@")"; then
    return 2
  fi
  if [[ "$resolved" != "$1" ]]; then
    echo "No \"$1\" script; running \"$resolved\"." >&2
  fi
  run_npm run "$resolved"
}

inst=2
lint=2
chk=2
bld=2
tst=2
status=0

if [[ ! -f "$pkg" ]]; then
  echo "No package.json in $DIR" >&2
  inst=1
  status=1
elif [[ -f "$DIR/package-lock.json" ]]; then
  if run_npm ci --no-audit --no-fund; then
    inst=0
  else
    inst=1
    status=1
  fi
else
  if run_npm install --no-audit --no-fund; then
    inst=0
  else
    inst=1
    status=1
  fi
fi

if [[ "$inst" -eq 0 ]]; then
  run_column lint
  lint=$?
  run_column check typecheck
  chk=$?
  run_column build
  bld=$?
  run_column test
  tst=$?
  if [[ "$lint" -eq 1 || "$chk" -eq 1 || "$bld" -eq 1 || "$tst" -eq 1 ]]; then
    status=1
  fi
fi

printf '| %s | %s | %s | %s | %s | %s |\n' \
  "$NAME" "$(icon "$inst")" "$(icon "$lint")" "$(icon "$chk")" "$(icon "$bld")" "$(icon "$tst")"
exit "$status"
