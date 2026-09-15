#!/usr/bin/env bash
# Fleet batch-change runner for the org's repositories.
#
# Clone each repo selected from the catalog, run a command inside it, and — with
# --apply — push a branch and open a pull request with the resulting changes.
# Dry-run by default: prints a diffstat per repo and opens no PRs.
#
# Examples:
#   # Preview bumping a dependency across every library (no PRs):
#   scripts/fleet-exec.sh --type library -- npm pkg set devDependencies.eslint=^9.0.0
#
#   # Apply a Biome autofix across all JS/TS repos and open one PR each:
#   scripts/fleet-exec.sh --type library --apply --install \
#     --branch chore/biome-fix --title "chore: biome autofix" -- npm run fix
#
# Auth: uses the `gh` CLI. Pushing branches and opening PRs in other repos needs a
# token with write access to those repos (your local `gh auth`, or an org PAT /
# GitHub App token exported as GH_TOKEN in CI — the default GITHUB_TOKEN is scoped
# only to the repo running the workflow).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"

ORG="${FLEET_ORG:-${OPENPHYSICS_ORG:-$(repos_org)}}"
BRANCH="chore/fleet-update"
TITLE=""
BODY="Automated fleet change opened by relay's fleet-exec runner."
COMMIT_MSG=""
APPLY=0
KEEP=0
INSTALL=0
CHECK_AUTH=0
LABELS=()
SKIPS=()
CMD=()

GIT_NAME="${FLEET_GIT_NAME:-github-actions[bot]}"
GIT_EMAIL="${FLEET_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

usage() {
  cat <<'EOF'
Usage: fleet-exec.sh [filters] [options] -- <command> [args...]

Clone each selected repo, run <command> in it, and (with --apply) open
a PR with the resulting changes. Dry-run by default.

Filters (from structure/repos.json):
  --type TYPE         Filter by type field (app|library|tool|config|template)
  --status STATUS     Filter by status (active|template|draft|wip|archived)
  --only NAME         Target a single repo by name (one-PR runs, smoke tests)
  --catalog PATH      Override path to repos.json

Options:
  --check-auth        Read-only preflight: verify the token can write (push) to
                      each selected repo, print a table, and exit. Opens nothing.
  --branch NAME       Branch to create in each repo (default: chore/fleet-update)
  --title TEXT        PR title (default: "chore: fleet update")
  --body TEXT         PR body
  --commit-message T  Commit message (default: PR title)
  --label LABEL       Add a label to each PR (repeatable; label must already exist)
  --skip NAME         Exclude a repo (repeatable)
  --install           Run `npm install` in each clone before the command
  --apply             Actually push branches and open PRs (otherwise dry-run)
  --keep              Keep the temporary clones instead of deleting them
  -h, --help          Show this help

Environment:
  GH_TOKEN                 Token for gh (write access needed for --apply)
  FLEET_GIT_NAME/_EMAIL    Commit identity (default: github-actions[bot])
EOF
}

repos_reset_filters
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) FILTER_TYPE="${2:?Missing value for --type}"; shift 2 ;;
    --status) FILTER_STATUS="${2:?Missing value for --status}"; shift 2 ;;
    --only) FILTER_NAME="${2:?Missing value for --only}"; shift 2 ;;
    --catalog) REPOS_JSON="${2:?Missing value for --catalog}"; shift 2 ;;
    --branch) BRANCH="${2:?Missing value for --branch}"; shift 2 ;;
    --title) TITLE="${2:?Missing value for --title}"; shift 2 ;;
    --body) BODY="${2:?Missing value for --body}"; shift 2 ;;
    --commit-message) COMMIT_MSG="${2:?Missing value for --commit-message}"; shift 2 ;;
    --label) LABELS+=("${2:?Missing value for --label}"); shift 2 ;;
    --skip) SKIPS+=("${2:?Missing value for --skip}"); shift 2 ;;
    --install) INSTALL=1; shift ;;
    --apply) APPLY=1; shift ;;
    --check-auth) CHECK_AUTH=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; CMD=("$@"); break ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $CHECK_AUTH -eq 0 && ${#CMD[@]} -eq 0 ]]; then
  echo "A command is required after -- (or use --check-auth for a read-only preflight)" >&2
  usage >&2
  exit 2
fi

TITLE="${TITLE:-chore: fleet update}"
COMMIT_MSG="${COMMIT_MSG:-$TITLE}"

for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

if [[ ( $APPLY -eq 1 || $CHECK_AUTH -eq 1 ) ]] && ! gh auth status >/dev/null 2>&1; then
  echo "This run requires an authenticated gh (set GH_TOKEN or run 'gh auth login')" >&2
  exit 1
fi

# --check-auth: read-only preflight. Ask the API whether the active token can push
# to each selected repo; open and change nothing. Exits non-zero if any can't be
# written, so an apply=true run won't start with a stale/under-scoped token.
if [[ $CHECK_AUTH -eq 1 ]]; then
  auth_total=0 auth_ok=0 auth_fail=0
  who="$(gh api user --jq .login 2>/dev/null || echo '?')"
  echo "Auth preflight as: $who"
  printf '%-28s %s\n' "REPO" "PUSH"
  for repo in $(repos_names); do
    auth_total=$((auth_total + 1))
    if push="$(gh api "repos/$ORG/$repo" --jq .permissions.push 2>/dev/null)" && [[ "$push" == "true" ]]; then
      printf '%-28s %s\n' "$repo" "✅ yes"
      auth_ok=$((auth_ok + 1))
    else
      printf '%-28s %s\n' "$repo" "❌ no"
      auth_fail=$((auth_fail + 1))
    fi
  done
  echo "----"
  echo "Auth: $auth_ok/$auth_total writable, $auth_fail without push access."
  [[ $auth_fail -eq 0 ]] && exit 0 || exit 1
fi

is_skipped() {
  local name="$1" s
  for s in ${SKIPS[@]+"${SKIPS[@]}"}; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

total=0 changed=0 opened=0 overall=0
NAMES="$(repos_names)"

for repo in $NAMES; do
  if is_skipped "$repo"; then
    echo "==== $repo (skipped) ===="
    continue
  fi
  total=$((total + 1))
  echo "==== $repo ===="

  workdir="$(mktemp -d)"
  cleanup() { [[ $KEEP -eq 1 ]] || rm -rf "$workdir"; }

  if ! gh repo clone "$ORG/$repo" "$workdir" -- --depth 1 --quiet 2>/dev/null; then
    echo "  clone failed"; overall=1; cleanup; continue
  fi

  base="$(git -C "$workdir" branch --show-current)"
  git -C "$workdir" checkout -q -b "$BRANCH"

  if [[ $INSTALL -eq 1 && -f "$workdir/package.json" ]]; then
    if ! ( cd "$workdir" && npm install --no-audit --no-fund >/dev/null 2>&1 ); then
      echo "  npm install failed"; overall=1; cleanup; continue
    fi
  fi

  if ! ( cd "$workdir" && REPO_NAME="$repo" "${CMD[@]}" ); then
    echo "  command failed"; overall=1; cleanup; continue
  fi

  # Ignore an npm-install-created node_modules / lockfile churn unless the command
  # touched the lockfile itself; node_modules is gitignored in every sim already.
  if [[ -z "$(git -C "$workdir" status --porcelain)" ]]; then
    echo "  no changes"; cleanup; continue
  fi

  changed=$((changed + 1))
  git -C "$workdir" --no-pager diff --stat | sed 's/^/  /'

  if [[ $APPLY -eq 0 ]]; then
    echo "  [dry-run] would commit, push '$BRANCH', and open a PR into '$base'"
    cleanup; continue
  fi

  git -C "$workdir" add -A
  git -C "$workdir" -c "user.name=$GIT_NAME" -c "user.email=$GIT_EMAIL" commit -q -m "$COMMIT_MSG"
  if ! git -C "$workdir" push -q -u origin "$BRANCH" 2>/dev/null; then
    echo "  push failed"; overall=1; cleanup; continue
  fi

  label_args=()
  for l in ${LABELS[@]+"${LABELS[@]}"}; do label_args+=(--label "$l"); done
  if pr_url="$( cd "$workdir" && gh pr create --base "$base" --head "$BRANCH" \
      --title "$TITLE" --body "$BODY" ${label_args[@]+"${label_args[@]}"} 2>&1 )"; then
    echo "  opened: $pr_url"; opened=$((opened + 1))
  else
    echo "  PR creation failed: $pr_url"; overall=1
  fi
  cleanup
done

echo "----"
echo "Summary: $total repo(s), $changed changed, $opened PR(s) opened."
if [[ $APPLY -eq 0 && $changed -gt 0 ]]; then
  echo "Dry-run only — re-run with --apply to push branches and open PRs."
fi
exit $overall
