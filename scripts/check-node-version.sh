#!/usr/bin/env bash
# Assert the fleet's default Node version is in sync across the workflows that
# declare it, and — when sibling fleet checkouts are present — that member
# package.json files track the same major (engines.node, devEngines.runtime, and
# @types/node when that dependency is present).
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
echo "Expected member-repo pins: engines.node \">=${FLEET_NODE_MAJOR}\", devEngines.runtime Node >=${FLEET_NODE_MAJOR} (onFail: error), and @types/node major ${FLEET_NODE_MAJOR} when that dependency is present"

# Check one package.json against the fleet major. Missing engines or
# devEngines is a failure: npm repos must refuse to run on an older Node.
checked=0
check_pkg() {
  local name="$1" pkg="$2"
  [[ -f "$pkg" ]] || return 0
  local dir meta engines rest types dev types_major pin pin_major pinfile
  dir="$(dirname "$pkg")"
  meta="$(python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
engines = (p.get('engines') or {}).get('node') or ''
types = (p.get('devDependencies') or {}).get('@types/node') or (p.get('dependencies') or {}).get('@types/node') or ''
rt = (p.get('devEngines') or {}).get('runtime') or {}
dev = (rt.get('version') or '') + '|' + (rt.get('onFail') or '') if rt.get('name') == 'node' else ''
print(engines + '\t' + types + '\t' + dev)
" "$pkg")"
  engines="${meta%%$'\t'*}"
  rest="${meta#*$'\t'}"
  types="${rest%%$'\t'*}"
  dev="${rest#*$'\t'}"
  checked=$((checked + 1))
  if [[ ! "$engines" =~ ^\>=${FLEET_NODE_MAJOR}(\.0\.0)?$ ]]; then
    fail "$name: engines.node must be >=${FLEET_NODE_MAJOR} (found: ${engines:-missing})"
  fi
  if [[ ! "$dev" =~ ^\>=${FLEET_NODE_MAJOR}(\.0\.0)?\|error$ ]]; then
    fail "$name: devEngines.runtime must be { name: node, version: >=${FLEET_NODE_MAJOR}, onFail: error } (found: ${dev:-missing})"
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
}

# Always check relay itself. When sibling fleet checkouts are present (local
# OpenPhysics workspace), also check every catalog repo that has a package.json.
# Skipped siblings are absent in relay-only CI.
check_pkg "relay" "$ROOT/package.json"
PARENT="$(cd "$ROOT/.." && pwd)"
CATALOG="$ROOT/structure/repos.json"
if [[ -d "$PARENT" && -f "$CATALOG" ]]; then
  while IFS= read -r name; do
    check_pkg "$name" "$PARENT/$name/package.json"
  done < <(jq -r '.repos[] | select(.name != "relay") | .name' "$CATALOG")
fi

if [[ $checked -gt 0 ]]; then
  if [[ $FAIL -eq 0 ]]; then
    echo "OK: $checked package.json pin(s) match Node $FLEET_NODE_MAJOR"
  fi
else
  echo "Note: no sibling member package.json pins found (workflow-only check)."
fi

if [ "$FAIL" -ne 0 ]; then
  echo "Node-version check failed."
  exit 1
fi

echo "Node-version check passed."
