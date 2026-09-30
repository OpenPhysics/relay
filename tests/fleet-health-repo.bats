#!/usr/bin/env bats
#
# scripts/fleet-health-repo.sh must print a markdown row even when a script is
# missing or failing. GitHub Actions runs steps under `bash -e`, and a bare
# non-zero return used to abort the health job before that row existed.

setup() {
  load 'helpers/common'
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  : >"$NPM_LOG"
  cat >"$STUB_BIN/npm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_LOG"
if [[ "${NPM_INSTALL_FAIL:-}" == 1 && ( "$1" == "ci" || "$1" == "install" ) ]]; then
  echo "install broke" >&2
  exit 1
fi
if [[ "$1" == "run" && "$2" == "${NPM_FAIL_SCRIPT:-}" ]]; then
  echo "$2 broke" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$STUB_BIN/npm"
}

probe() {
  # shellcheck disable=SC2068
  run env \
    PATH="$STUB_BIN:$PATH" \
    NPM_LOG="$NPM_LOG" \
    NPM_INSTALL_FAIL="${NPM_INSTALL_FAIL:-}" \
    NPM_FAIL_SCRIPT="${NPM_FAIL_SCRIPT:-}" \
    bash --noprofile --norc -eo pipefail \
    "$RELAY_ROOT/scripts/fleet-health-repo.sh" \
    --name demo "$REPO" "$@"
}

write_pkg() {
  local scripts="$1"
  printf '{ "name": "demo", "scripts": %s }\n' "$scripts" >"$REPO/package.json"
  : >"$REPO/package-lock.json"
}

@test "missing scripts are skips and the row is still printed under bash -e" {
  write_pkg '{"build":"true"}'
  probe
  assert_success
  assert_output --partial "| demo | ✅ | — | — | ✅ | — |"
}

@test "a failing lint fails the probe and still prints the row" {
  write_pkg '{"lint":"true","check":"true","build":"true","test":"true"}'
  NPM_FAIL_SCRIPT=lint
  probe
  assert_failure
  assert_output --partial "| demo | ✅ | ❌ | ✅ | ✅ | ✅ |"
  assert_output --partial "lint broke"
}

@test "check is preferred over typecheck" {
  write_pkg '{"check":"true","typecheck":"true","build":"true"}'
  probe
  assert_success
  assert_output --partial "| demo | ✅ | — | ✅ | ✅ | — |"
  run grep -F "run check" "$NPM_LOG"
  assert_success
  run grep -F "run typecheck" "$NPM_LOG"
  assert_failure
}

@test "typecheck runs when check is absent" {
  write_pkg '{"typecheck":"true","build":"true"}'
  probe
  assert_success
  assert_output --partial "| demo | ✅ | — | ✅ | ✅ | — |"
  assert_output --partial 'No "check" script; running "typecheck".'
  run grep -F "run typecheck" "$NPM_LOG"
  assert_success
}

@test "install failure is a failed row and does not run scripts" {
  write_pkg '{"lint":"true","test":"true"}'
  NPM_INSTALL_FAIL=1
  probe
  assert_failure
  assert_output --partial "| demo | ❌ | — | — | — | — |"
  run grep -F "run lint" "$NPM_LOG"
  assert_failure
}

@test "ci.yml accepts the same check and typecheck names" {
  run grep -F '.scripts.typecheck' "$RELAY_ROOT/.github/workflows/ci.yml"
  assert_success
  run grep -F '.scripts.check' "$RELAY_ROOT/.github/workflows/ci.yml"
  assert_success
  run grep -F '.scripts.lint' "$RELAY_ROOT/.github/workflows/ci.yml"
  assert_success
}
