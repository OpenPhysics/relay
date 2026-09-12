#!/usr/bin/env bash
# Clone (or update) every repo in structure/repos.json into the
# workspace, side by side. This is what turns an empty workspace — or the thin
# superproject — into the full org checkout the other scripts expect.
#
# repos.json is the single source of truth: there are no submodules, so adding a
# repo to the catalog is all it takes for this to clone it. Missing repos are
# cloned; repos already on disk are left untouched unless --update is given,
# which fast-forwards each to its remote. Reuses the same catalog filters as
# parse-repos.sh.
#
# Examples:
#   # Populate the workspace (clone whatever is missing):
#   scripts/clone-fleet.sh
#
#   # Only libraries, and fast-forward any already present:
#   scripts/clone-fleet.sh --type library --update
#
#   # See the plan, change nothing:
#   scripts/clone-fleet.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"

ORG="${FLEET_ORG:-${OPENPHYSICS_ORG:-$(repos_org)}}"
SCHEME="ssh"
UPDATE=0
DRY_RUN=0
SKIPS=()

usage() {
  cat <<'EOF'
Usage: clone-fleet.sh [filters] [options]

Clone every repository in structure/repos.json into the workspace as a sibling
directory. Re-runnable: repos already present are skipped (use --update to
fast-forward them).

Filters (from structure/repos.json):
  --type TYPE         Filter by type field (app|library|tool|config|template)
  --status STATUS     Filter by status (active|template|draft|wip|archived)
  --only NAME         Clone a single repo by name
  --skip NAME         Exclude a repo (repeatable)
  --catalog PATH      Override path to repos.json

Options:
  --update            Fast-forward (git pull --ff-only) repos already on disk
  --https             Clone over HTTPS instead of SSH (default: SSH)
  --ssh               Clone over SSH (default)
  -n, --dry-run       Print the plan and change nothing
  -h, --help          Show this help

Environment:
  FLEET_WORKSPACE         Workspace root to clone into (default: relay/..)
EOF
}

repos_reset_filters
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) FILTER_TYPE="${2:?Missing value for --type}"; shift 2 ;;
    --status) FILTER_STATUS="${2:?Missing value for --status}"; shift 2 ;;
    --only) FILTER_NAME="${2:?Missing value for --only}"; shift 2 ;;
    --skip) SKIPS+=("${2:?Missing value for --skip}"); shift 2 ;;
    --catalog) REPOS_JSON="${2:?Missing value for --catalog}"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --https) SCHEME="https"; shift ;;
    --ssh) SCHEME="ssh"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

clone_url() {
  local name="$1"
  if [[ "$SCHEME" == "https" ]]; then
    printf 'https://github.com/%s/%s.git\n' "$ORG" "$name"
  else
    printf 'git@github.com:%s/%s.git\n' "$ORG" "$name"
  fi
}

is_skipped() {
  local name="$1" s
  for s in ${SKIPS[@]+"${SKIPS[@]}"}; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

WORKSPACE="$(repos_workspace_root)"
total=0 cloned=0 updated=0 present=0 failed=0

for repo in $(repos_names); do
  if is_skipped "$repo"; then
    echo "==== $repo (skipped) ===="
    continue
  fi
  total=$((total + 1))
  dest="$WORKSPACE/$repo"
  url="$(clone_url "$repo")"

  if [[ -d "$dest/.git" ]]; then
    if [[ $UPDATE -eq 0 ]]; then
      echo "==== $repo (present) ===="
      present=$((present + 1))
      continue
    fi
    echo "==== $repo (update) ===="
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [dry-run] git -C $dest pull --ff-only"
    elif git -C "$dest" pull --ff-only --quiet; then
      echo "  updated"; updated=$((updated + 1))
    else
      echo "  update failed (diverged from remote?)"; failed=$((failed + 1))
    fi
    continue
  fi

  echo "==== $repo (clone) ===="
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] git clone $url $dest"
    continue
  fi
  if git clone --quiet "$url" "$dest"; then
    echo "  cloned"; cloned=$((cloned + 1))
  else
    echo "  clone failed: $url"; failed=$((failed + 1))
  fi
done

echo "----"
echo "Summary: $total repo(s) — $cloned cloned, $updated updated, $present present, $failed failed."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry-run only — re-run without --dry-run to clone/update."
fi
[[ $failed -eq 0 ]]
