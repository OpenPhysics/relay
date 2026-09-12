#!/usr/bin/env bash
# Generic compliance checks for OpenPhysics member repositories.
#
# Deliberately light: the fleet spans multiple languages and repo shapes (an
# app, several libraries, this tool), so there is no single fixed file layout
# to assert here. This checks what genuinely applies to every repo — CI
# wiring to Relay's reusable workflows, Dependabot presence, Node-version
# consistency for npm repos, a README and license, and GitHub security
# settings — and nothing narrower.
set -euo pipefail

# Resolve before the cd below: BASH_SOURCE may be a relative path, and it stops
# resolving once the working directory moves into the repo under test.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RELAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="${FLEET_CATALOG:-${OPENPHYSICS_CATALOG:-$RELAY_ROOT/structure/repos.json}}"

ORG="${FLEET_ORG:-${OPENPHYSICS_ORG:-$(jq -r '.organization' "$CATALOG")}}"

REPO_DIR="${1:?Repository directory required}"
cd "$REPO_DIR"

echo "Checking compliance in: $(pwd)"
FAIL=0
WARN=0

fail() {
  echo "FAIL: $1"
  FAIL=1
}

warn() {
  echo "WARN: $1"
  WARN=1
}

pass() {
  echo "OK: $1"
}

if [ -f README.md ] && [ -s README.md ]; then
  pass "README.md present"
else
  fail "README.md is missing or empty"
fi

if [ -f LICENSE ] || [ -f LICENSE.md ] || [ -f LICENSE.txt ]; then
  pass "LICENSE present"
else
  warn "no LICENSE at repo root"
fi

if [ ! -f .github/workflows/ci.yml ]; then
  warn ".github/workflows/ci.yml is missing (not yet wired to Relay's reusable CI)"
elif grep -q "$ORG/Relay/.github/workflows/ci.yml@main" .github/workflows/ci.yml; then
  pass "ci.yml uses Relay's reusable workflow"
  if ! grep -q "$ORG/Relay/.github/workflows/shared-dependency-review.yml@main" .github/workflows/ci.yml; then
    warn "ci.yml does not call shared-dependency-review.yml"
  fi
  if ! grep -q "$ORG/Relay/.github/workflows/shared-codeql.yml@main" .github/workflows/ci.yml; then
    warn "ci.yml does not call shared-codeql.yml"
  fi
else
  warn "ci.yml exists but does not call $ORG/Relay's reusable workflow"
fi

if [ -f package.json ]; then
  if [ -f .github/dependabot.yml ]; then
    pass "dependabot.yml present"
  else
    warn ".github/dependabot.yml is missing for npm repository"
  fi

  # Node engine / @types/node should track Relay's fleet Node major (ci.yml default).
  CI_YML="$RELAY_ROOT/.github/workflows/ci.yml"
  EXPECTED_NODE_MAJOR=""
  if [ -f "$CI_YML" ]; then
    EXPECTED_NODE_MAJOR="$(grep -oP 'default:\s*["'\'']\K[0-9]+' "$CI_YML" | head -n1 || true)"
  fi
  EXPECTED_NODE_MAJOR="${EXPECTED_NODE_MAJOR:-24}"

  ENGINES_NODE="$(python3 -c "import json; print((json.load(open('package.json')).get('engines') or {}).get('node') or '')" 2>/dev/null || true)"
  if [ -z "$ENGINES_NODE" ]; then
    warn "package.json engines.node is missing (expected >=${EXPECTED_NODE_MAJOR})"
  elif [[ ! "$ENGINES_NODE" =~ ^\>=${EXPECTED_NODE_MAJOR}(\.0\.0)?$ ]]; then
    warn "engines.node is $ENGINES_NODE, fleet default is >=${EXPECTED_NODE_MAJOR}"
  else
    pass "engines.node is $ENGINES_NODE"
  fi
elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
  if [ -f .github/dependabot.yml ]; then
    pass "dependabot.yml present"
  else
    warn ".github/dependabot.yml is missing for python repository"
  fi
fi

REPO_NAME=""
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  REPO_NAME="${GITHUB_REPOSITORY##*/}"
fi
if [ -z "$REPO_NAME" ]; then
  REPO_NAME="$(basename "$REPO_DIR")"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  VULN_ALERTS=$(gh api graphql -f query='query($o:String!,$n:String!){ repository(owner:$o,name:$n){ hasVulnerabilityAlertsEnabled isPrivate } }' -f o="$ORG" -f n="$REPO_NAME" --jq '.data.repository.hasVulnerabilityAlertsEnabled' 2>/dev/null || echo "")
  if [ "$VULN_ALERTS" = "true" ]; then
    pass "Dependabot vulnerability alerts enabled"
  elif [ -n "$VULN_ALERTS" ]; then
    warn "Dependabot vulnerability alerts are not enabled on GitHub"
  else
    warn "Could not verify GitHub vulnerability alerts (gh query failed)"
  fi

  SEC_JSON=$(gh api "repos/$ORG/$REPO_NAME" --jq '.security_and_analysis // {}' 2>/dev/null || echo "{}")
  IS_PRIVATE=$(gh api "repos/$ORG/$REPO_NAME" --jq '.private' 2>/dev/null || echo "false")
  if [ -n "$SEC_JSON" ] && [ "$SEC_JSON" != "{}" ] && [ "$SEC_JSON" != "null" ]; then
    DEP_UPDATES=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("dependabot_security_updates",{}).get("status","unknown"))' <<<"$SEC_JSON")
    if [ "$DEP_UPDATES" = "enabled" ]; then
      pass "Dependabot security updates enabled"
    else
      warn "Dependabot security updates are not enabled on GitHub"
    fi

    if [ "$IS_PRIVATE" != "true" ]; then
      SECRET_SCAN=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("secret_scanning",{}).get("status","unknown"))' <<<"$SEC_JSON")
      if [ "$SECRET_SCAN" = "enabled" ]; then
        pass "secret scanning enabled"
      else
        warn "Secret scanning is not enabled on GitHub"
      fi
    else
      pass "private repo: secret scanning check skipped"
    fi
  elif [ "$IS_PRIVATE" = "true" ]; then
    pass "private repo: dependabot security updates assumed enabled when vulnerability alerts are on"
  else
    warn "Could not read security_and_analysis settings from GitHub"
  fi
else
  warn "gh not available; skipping live GitHub security setting checks"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "Compliance check failed."
  exit 1
fi

if [ "$WARN" -ne 0 ]; then
  echo "Compliance check passed with warnings."
else
  echo "Compliance check passed."
fi
