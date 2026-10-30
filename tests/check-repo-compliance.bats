#!/usr/bin/env bats
#
# Behavioural tests for scripts/check-repo-compliance.sh.
#
# The failure mode this guards against is a compliance rule that quietly stops
# firing: the audit still exits 0, so the fleet reads as green while the rule is
# dead. Every test below starts from a fixture that passes cleanly, breaks
# exactly one rule, and asserts the audit reports that rule's message.

setup() {
  load 'helpers/common'
  stub_gh
  REPO="$BATS_TEST_TMPDIR/repo"
  make_compliant_repo "$REPO"
}

# ── Baseline ──────────────────────────────────────────────────────────────────

@test "compliant fixture passes with only the stubbed-gh warning" {
  run_compliance "$REPO"
  assert_success
  refute_output --partial "FAIL:"
  assert_output --partial "Compliance check passed"
  local warnings
  warnings="$(printf '%s\n' "$output" | grep -c '^WARN:' || true)"
  [ "$warnings" -eq 1 ]
  assert_output --partial "WARN: gh not available"
}

# ── README / license ──────────────────────────────────────────────────────────

@test "missing README.md fails" {
  rm "$REPO/README.md"
  run_compliance "$REPO"
  assert_failure
  assert_output --partial "FAIL: README.md is missing"
}

@test "empty README.md fails" {
  : >"$REPO/README.md"
  run_compliance "$REPO"
  assert_failure
  assert_output --partial "FAIL: README.md is missing"
}

@test "missing LICENSE warns" {
  rm "$REPO/LICENSE"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "WARN: no LICENSE"
}

# ── CI wiring ─────────────────────────────────────────────────────────────────

@test "missing ci.yml warns" {
  rm "$REPO/.github/workflows/ci.yml"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "WARN: .github/workflows/ci.yml is missing"
}

@test "ci.yml not calling relay's reusable workflow warns" {
  sed -i "s|$(fleet_org)/relay/.github/workflows/ci.yml@main|some/other/workflow.yml@main|" "$REPO/.github/workflows/ci.yml"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "ci.yml exists but does not call $(fleet_org)/relay's reusable workflow"
}

@test "ci.yml without shared-dependency-review warns" {
  sed -i '/shared-dependency-review/d' "$REPO/.github/workflows/ci.yml"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "ci.yml does not call shared-dependency-review.yml"
}

@test "ci.yml without shared-codeql warns" {
  sed -i '/shared-codeql/d' "$REPO/.github/workflows/ci.yml"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "ci.yml does not call shared-codeql.yml"
}

@test "missing dependabot.yml warns for an npm repo" {
  rm "$REPO/.github/dependabot.yml"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "dependabot.yml is missing for npm repository"
}

# ── Node pins ─────────────────────────────────────────────────────────────────

@test "missing engines.node fails" {
  local major
  major="$(fleet_node_major)"
  echo '{"name": "fixture-lib"}' >"$REPO/package.json"
  run_compliance "$REPO"
  assert_failure
  assert_output --partial "engines.node is missing (expected >=${major})"
}

@test "engines.node below the fleet major fails" {
  local major
  major="$(fleet_node_major)"
  python3 - "$REPO/package.json" "$major" <<'PY'
import json, sys
path, major = sys.argv[1], sys.argv[2]
pkg = json.load(open(path))
pkg["engines"]["node"] = ">=18"
json.dump(pkg, open(path, "w"))
PY
  run_compliance "$REPO"
  assert_failure
  assert_output --partial "engines.node must be >=${major} to match fleet Node (found: >=18)"
}

@test "missing devEngines.runtime fails" {
  local major
  major="$(fleet_node_major)"
  python3 - "$REPO/package.json" <<'PY'
import json, sys
path = sys.argv[1]
pkg = json.load(open(path))
pkg.pop("devEngines", None)
json.dump(pkg, open(path, "w"))
PY
  run_compliance "$REPO"
  assert_failure
  assert_output --partial "devEngines.runtime must be { name: node, version: >=${major}, onFail: error }"
}

@test "@types/node on an older major fails" {
  local major
  major="$(fleet_node_major)"
  python3 - "$REPO/package.json" <<'PY'
import json, sys
path = sys.argv[1]
pkg = json.load(open(path))
pkg["devDependencies"] = {"@types/node": "^18.0.0"}
json.dump(pkg, open(path, "w"))
PY
  run_compliance "$REPO"
  assert_failure
  assert_output --partial "@types/node major must be ${major} to match fleet Node (found: ^18.0.0)"
}

# ── Python repos ──────────────────────────────────────────────────────────────

@test "python repo without dependabot.yml warns" {
  rm "$REPO/package.json" "$REPO/.github/dependabot.yml"
  touch "$REPO/pyproject.toml"
  run_compliance "$REPO"
  assert_success
  assert_output --partial "dependabot.yml is missing for python repository"
}
