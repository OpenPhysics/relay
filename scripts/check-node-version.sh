#!/usr/bin/env bash
# Assert the fleet's default Node version is in sync across the workflows that
# declare it, and — when sibling fleet checkouts are present — that member
# package.json files track the same major (engines.node floor + @types/node).
# README.md ("Node version") says these "must stay in sync" — this turns that
# prose warning into an enforced check.
#
#   scripts/check-node-version.sh
#
# Exits non-zero (and prints what disagrees) if the versions diverge.
# Per-repo CI enforcement of engines/@types/node lives in check-repo-compliance.sh
# (which derives the expected major from relay's ci.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WF="$ROOT/.github/workflows"

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }

# Each entry: "label|file|extractor" where extractor is a grep -oP that yields the version.
declare -A VERSIONS

extract() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || { fail "missing workflow: ${file#"$ROOT/"}"; return 1; }
  grep -oP "$pattern" "$file" | head -n1
}

# Quotes may be single or double across the workflows, so match either.
# ci.yml / deploy.yml declare it as the `node-version` input `default:`.
VERSIONS[ci.yml]="$(extract "$WF/ci.yml" $'default:\\s*["\']\\K[0-9]+(?=["\'])' || true)"
VERSIONS[deploy.yml]="$(extract "$WF/deploy.yml" $'default:\\s*["\']\\K[0-9]+(?=["\'])' || true)"
# Other workflows: node-version on the setup-node step.
for f in fleet-health.yml fleet-exec.yml; do
  VERSIONS[$f]="$(extract "$WF/$f" $'node-version:\\s*["\']\\K[0-9]+(?=["\'])' || true)"
done

FILES=(ci.yml deploy.yml fleet-health.yml fleet-exec.yml)

echo "Declared Node versions:"
for f in "${FILES[@]}"; do
  v="${VERSIONS[$f]:-}"
  echo "  $f: ${v:-<not found>}"
  [ -n "$v" ] || fail "$f: could not extract a Node version"
done

# All present versions must be identical.
uniq_versions="$(printf '%s\n' "${VERSIONS[@]}" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$FAIL" -eq 0 ] && [ "$(printf '%s' "$uniq_versions" | wc -w)" -ne 1 ]; then
  fail "Node versions diverge across workflows: $uniq_versions — bump all declared workflows together (see README 'Node version')"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "Node-version check failed."
  exit 1
fi

FLEET_NODE_MAJOR="$uniq_versions"
echo "OK: all workflows agree on Node $FLEET_NODE_MAJOR"
echo "Expected member-repo pins: engines.node \">=${FLEET_NODE_MAJOR}\" and @types/node major ${FLEET_NODE_MAJOR}"

# Optional workspace scan: when relay lives beside sibling checkouts (local
# bootstrap layout), assert catalog member pins match, for every sibling repo
# that actually has a package.json. Skipped in relay-only CI.
PARENT="$(cd "$ROOT/.." && pwd)"
CATALOG="$ROOT/structure/repos.json"
checked=0
if [[ -d "$PARENT" && -f "$CATALOG" ]]; then
  while IFS= read -r name; do
    pkg="$PARENT/$name/package.json"
    [[ -f "$pkg" ]] || continue
    dir="$PARENT/$name"
    meta="$(python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
engines = (p.get('engines') or {}).get('node') or ''
types = (p.get('devDependencies') or {}).get('@types/node') or (p.get('dependencies') or {}).get('@types/node') or ''
print(engines + '\t' + types)
" "$pkg")"
    engines="${meta%%$'\t'*}"
    types="${meta#*$'\t'}"
    [[ -z "$engines" && -z "$types" ]] && continue
    checked=$((checked + 1))
    if [[ -n "$engines" && ! "$engines" =~ ^\>=${FLEET_NODE_MAJOR}(\.0\.0)?$ ]]; then
      fail "$name: engines.node must be >=${FLEET_NODE_MAJOR} (found: $engines)"
    fi
    if [[ -n "$types" ]]; then
      types_major="$(sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$types")"
      if [[ "$types_major" != "$FLEET_NODE_MAJOR" ]]; then
        fail "$name: @types/node major must be ${FLEET_NODE_MAJOR} (found: $types)"
      fi
    fi
    for pinfile in .nvmrc .node-version; do
      if [[ -f "$dir/$pinfile" ]]; then
        pin="$(tr -d 'v[:space:]' <"$dir/$pinfile")"
        pin_major="${pin%%.*}"
        if [[ "$pin_major" != "$FLEET_NODE_MAJOR" ]]; then
          fail "$name: $pinfile pins Node $pin but fleet major is $FLEET_NODE_MAJOR"
        fi
      fi
    done
  done < <(jq -r '.repos[] | select(.name != "relay") | .name' "$CATALOG")
fi

if [[ $checked -gt 0 ]]; then
  if [[ $FAIL -eq 0 ]]; then
    echo "OK: $checked sibling package.json pin(s) match Node $FLEET_NODE_MAJOR"
  fi
else
  echo "Note: no sibling member package.json pins found (workflow-only check)."
fi

if [ "$FAIL" -ne 0 ]; then
  echo "Node-version check failed."
  exit 1
fi

echo "Node-version check passed."
