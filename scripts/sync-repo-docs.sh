#!/usr/bin/env bash
# Rewrite every org-qualified reference in member repos to match the catalog.
#
# This is the counterpart to sync-dependabot.sh for the references that live in
# prose and workflow files: CI badges, org LICENSE and CONTRIBUTING links, the
# SECURITY.md catalog link, package.json repository URLs, Pages URLs, and the
# `uses:` calls into Relay.
#
# The organization is read from structure/repos.json, so renaming the org is a
# one-field edit followed by one run of this script:
#
#   scripts/sync-repo-docs.sh --from OldOrg --dry-run    # preview every change
#   scripts/sync-repo-docs.sh --from OldOrg              # apply in place
#
# Only owners listed with --from are rewritten (repeatable; defaults to the
# catalog org, making a run idempotent). That guard keeps third-party links such
# as github.com/some-other-org/... untouched even when a repo name happens to collide.
#
# Writes files only - committing, pushing, and opening PRs is left to you or to
# fleet-exec.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"

repos_require_jq

ORG="${FLEET_ORG:-${OPENPHYSICS_ORG:-$(repos_org)}}"
# Keep the Pages base consistent with whatever org we resolved: overriding
# FLEET_ORG for a dry run must not leave the old org's Pages host behind.
if [[ -n "${FLEET_ORG:-}${OPENPHYSICS_ORG:-}" ]]; then
  PAGES_BASE="${FLEET_PAGES_BASE:-https://${ORG,,}.github.io}"
else
  PAGES_BASE="${FLEET_PAGES_BASE:-$(repos_pages_base)}"
fi
WORKSPACE="$(repos_workspace_root)"
CATALOG="$(repos_catalog_path)"

DRY_RUN=0
FROM_OWNERS=()
FILTER=()

usage() {
  cat <<EOF
Usage: sync-repo-docs.sh [--from OWNER]... [--dry-run] [REPO...]

Rewrite org-qualified references in member repos to match the catalog
(organization = $ORG, pagesBase = $PAGES_BASE).

  --from OWNER   Owner to rewrite from; repeatable. Default: $ORG (idempotent).
  --dry-run      Report what would change; write nothing.
  REPO...        Limit to named repos (default: every catalog repo checked out).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM_OWNERS+=("${2:?Missing value for --from}"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) FILTER+=("$1"); shift ;;
  esac
done

[[ ${#FROM_OWNERS[@]} -eq 0 ]] && FROM_OWNERS=("$ORG")

mapfile -t CATALOG_REPOS < <(jq -r '.repos[].name' "$CATALOG")

wants() {
  [[ ${#FILTER[@]} -eq 0 ]] && return 0
  local name="$1" f
  for f in "${FILTER[@]}"; do [[ "$f" == "$name" ]] && return 0; done
  return 1
}

changed=0
missing=0
for repo in "${CATALOG_REPOS[@]}"; do
  wants "$repo" || continue
  dir="$WORKSPACE/$repo"
  if [[ ! -d "$dir/.git" ]]; then
    missing=$((missing + 1))
    continue
  fi

  result="$(
    ORG="$ORG" PAGES_BASE="$PAGES_BASE" REPO="$repo" DIR="$dir" DRY_RUN="$DRY_RUN" \
    FROM_OWNERS="$(printf '%s\n' "${FROM_OWNERS[@]}")" \
    CATALOG_REPOS="$(printf '%s\n' "${CATALOG_REPOS[@]}")" \
    python3 "$SCRIPT_DIR/lib/rewrite_org_refs.py"
  )" && rc=0 || rc=$?
  [[ -n "$result" ]] && echo "$result"
  [[ "$rc" -eq 10 ]] && changed=$((changed + 1))
done

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: $changed repo(s) would change, $missing not checked out."
else
  echo "Done: $changed repo(s) updated, $missing not checked out."
fi
