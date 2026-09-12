# Shared bats helpers for the Relay script tests.
#
# Loaded by every *.bats file via `load helpers/common`.

source "${BATS_TEST_DIRNAME}/../node_modules/bats-support/load.bash"
source "${BATS_TEST_DIRNAME}/../node_modules/bats-assert/load.bash"

RELAY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export RELAY_ROOT

# The fleet Node major, read from the same place check-repo-compliance.sh reads it
# (Relay's ci.yml `node-version` default). Fixtures derive their pins from this so
# the suite survives a fleet Node bump.
fleet_node_major() {
  grep -oP 'default:\s*["'\'']\K[0-9]+' "$RELAY_ROOT/.github/workflows/ci.yml" | head -n1
}

# The org login, read from the same source the scripts read it from, so the
# suite survives an organization rename without touching a single fixture.
fleet_org() {
  jq -r '.organization' "$RELAY_ROOT/structure/repos.json"
}

# check-repo-compliance.sh queries live GitHub security settings when `gh` is
# installed and authenticated. Shadow it with a stub that fails `auth status` so
# the suite is hermetic and offline: the script takes its documented
# "gh not available" branch (a warning, not a failure).
stub_gh() {
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN/gh"
}

# Run the compliance checker against a fixture repo with `gh` stubbed out.
run_compliance() {
  run env PATH="$STUB_BIN:$PATH" "$RELAY_ROOT/scripts/check-repo-compliance.sh" "$1"
}

# Build an npm repo fixture that satisfies every compliance rule.
# Individual tests copy this and break exactly one thing, so a rule that stops
# firing shows up as a failing test rather than a silently green audit.
make_compliant_repo() {
  local dir="$1"
  local major org
  major="$(fleet_node_major)"
  org="$(fleet_org)"

  mkdir -p "$dir/.github/workflows"

  cat >"$dir/README.md" <<'EOF'
# Fixture Library

A compliant repo fixture.
EOF

  touch "$dir/LICENSE"

  cat >"$dir/.github/workflows/ci.yml" <<EOF
name: CI
on: [push, pull_request]
jobs:
  ci:
    uses: ${org}/Relay/.github/workflows/ci.yml@main
  dependency-review:
    uses: ${org}/Relay/.github/workflows/shared-dependency-review.yml@main
  codeql:
    uses: ${org}/Relay/.github/workflows/shared-codeql.yml@main
EOF

  cat >"$dir/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
EOF

  cat >"$dir/package.json" <<EOF
{
  "name": "fixture-lib",
  "version": "1.0.0",
  "type": "module",
  "engines": { "node": ">=${major}" }
}
EOF
}
