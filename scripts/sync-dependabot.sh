#!/usr/bin/env bash
# Sync canonical Dependabot configs from Relay/config/ to the fleet repositories.
#
# Targets are read from structure/repos.json (not a hardcoded list):
#   - Relay itself          → config/dependabot-npm.yml (Relay ships a package.json with devDeps)
#   - .github (org profile) → config/dependabot-actions.yml (actions-only; no package.json)
#   - repos with language "JavaScript" or "TypeScript" → config/dependabot-npm.yml
#   - repos with language "Python"                     → config/dependabot-pip.yml
#
# Writes sibling checkouts under FLEET_WORKSPACE; skips repos that are not
# present locally (clone with clone-fleet.sh first). Commit/push is left to you
# or to fleet-exec.sh.
#
#   scripts/sync-dependabot.sh --dry-run     # show targets only
#   scripts/sync-dependabot.sh               # copy templates
#   scripts/sync-dependabot.sh DopplerEffect # limit to named repo(s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
CATALOG="${FLEET_CATALOG:-${OPENPHYSICS_CATALOG:-$REPO_ROOT/structure/repos.json}}"
WORKSPACE="${FLEET_WORKSPACE:-${OPENPHYSICS_WORKSPACE:-$(cd "$REPO_ROOT/.." && pwd)}}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "missing catalog: $CATALOG" >&2; exit 1; }

DRY_RUN=0
FILTER=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) FILTER+=("$arg") ;;
  esac
done

wants() {
  [ "${#FILTER[@]}" -eq 0 ] && return 0
  local name="$1"
  for f in "${FILTER[@]}"; do [ "$f" = "$name" ] && return 0; done
  return 1
}

# Like wants(), but for Relay's own file and the .github org profile. When a
# caller names specific repos, a scoped run must never silently dirty Relay or
# .github as a side effect — only touch them when they are explicitly named or
# no filter was given (the whole-fleet case).
self_wants() {
  [ "${#FILTER[@]}" -eq 0 ] && return 0
  local self="$1"
  for f in "${FILTER[@]}"; do [ "$f" = "$self" ] && return 0; done
  return 1
}

sync_file() {
  local template="$1"
  local target="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "WOULD sync $template → $target"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cp "$template" "$target"
  echo "Synced $target"
}

# npm repos: catalog entries whose language includes JavaScript or TypeScript.
mapfile -t NPM_REPOS < <(
  jq -r '
    .repos[]
    | select(
        .name != "Relay" and .name != ".github" and
        ((.language // []) | any(. == "JavaScript" or . == "TypeScript"))
      )
    | .name
  ' "$CATALOG" | sort
)

# pip repos: catalog entries whose language includes Python.
mapfile -t PIP_REPOS < <(
  jq -r '.repos[] | select((.language // []) | any(. == "Python")) | .name' "$CATALOG" | sort
)

echo "Syncing Dependabot configs from $CONFIG_DIR"
echo "Catalog: $CATALOG"
echo "Workspace: $WORKSPACE"
[ "$DRY_RUN" -eq 1 ] && echo "(dry-run — no files written)"

# Relay itself ships a package.json with devDeps → npm config. Gated so a
# scoped run (specific repos named) doesn't dirty Relay's working tree.
self_wants "Relay" && sync_file "$CONFIG_DIR/dependabot-npm.yml" "$REPO_ROOT/.github/dependabot.yml"

# The .github org-profile repo is actions-only (no package.json).
self_wants ".github" && sync_file "$CONFIG_DIR/dependabot-actions.yml" "$WORKSPACE/.github/.github/dependabot.yml"

npm_synced=0
npm_skipped=0
for repo in "${NPM_REPOS[@]}"; do
  wants "$repo" || continue
  dir="$WORKSPACE/$repo"
  if [ ! -d "$dir" ]; then
    echo "SKIP $repo (not checked out at $dir)"
    npm_skipped=$((npm_skipped + 1))
    continue
  fi
  sync_file "$CONFIG_DIR/dependabot-npm.yml" "$dir/.github/dependabot.yml"
  npm_synced=$((npm_synced + 1))
done

pip_synced=0
pip_skipped=0
for repo in "${PIP_REPOS[@]}"; do
  wants "$repo" || continue
  dir="$WORKSPACE/$repo"
  if [ ! -d "$dir" ]; then
    echo "SKIP $repo (not checked out at $dir)"
    pip_skipped=$((pip_skipped + 1))
    continue
  fi
  sync_file "$CONFIG_DIR/dependabot-pip.yml" "$dir/.github/dependabot.yml"
  pip_synced=$((pip_synced + 1))
done

echo "Dependabot sync complete: npm $npm_synced synced ($npm_skipped skipped), pip $pip_synced synced ($pip_skipped skipped)."
