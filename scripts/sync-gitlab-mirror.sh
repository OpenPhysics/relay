#!/usr/bin/env bash
# Mirror every repository in the org from GitHub to a GitLab group, as an
# off-GitHub backup of the fleet's git history.
#
# Scope is deliberately narrow: **git data only** — branches, tags, and the
# commits they reach. Issues, pull requests, releases, Actions workflows, and
# Pages deployments are not copied and are switched off on the GitLab side, so
# the mirror stays a plain backup rather than a half-working second home.
#
# Direction is GitHub -> GitLab, driven from here. (GitLab's own "pull mirror"
# would do this server-side but is a paid feature; pushing from our side works
# on the free tier and keeps the schedule in Relay.) The same command does the
# first import and every later sync: a bare mirror is cached per repo under
# --work-dir, so subsequent runs fetch and push only new objects.
#
# structure/repos.json is the source of truth for what gets mirrored, with the
# same filters as parse-repos.sh / clone-fleet.sh.
#
# Examples:
#   # First import of the whole fleet (creates the GitLab projects):
#   scripts/sync-gitlab-mirror.sh
#
#   # See the plan, change nothing:
#   scripts/sync-gitlab-mirror.sh --dry-run
#
#   # Periodic sync of the libraries only:
#   scripts/sync-gitlab-mirror.sh --type library
#
#   # Is the backup current? (read-only, no clones)
#   scripts/sync-gitlab-mirror.sh --check
#
# Requires: git, curl, jq, and a GitLab token in $GITLAB_TOKEN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"

ORG="${FLEET_ORG:-${OPENPHYSICS_ORG:-$(repos_org)}}"
GITHUB_BASE="${GITHUB_BASE:-https://github.com}"
GITLAB_HOST="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_GROUP="${GITLAB_GROUP:-$ORG}"
VISIBILITY="${GITLAB_VISIBILITY:-private}"
WORK_DIR="${GITLAB_MIRROR_WORK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/${ORG,,}/gitlab-mirror}"
MODE="sync"
DRY_RUN=0
FRESH=0
PRUNE=1
SKIPS=()

usage() {
  cat <<'EOF'
Usage: sync-gitlab-mirror.sh [filters] [options]

Mirror the GitHub repositories in structure/repos.json to a GitLab group as a
backup. Copies git data only — branches, tags, commits. Issues, merge requests,
CI, and Pages are not copied and are disabled on projects this script creates.

Re-runnable: the first run creates the GitLab projects and pushes everything,
later runs push only what is new.

Modes:
      --sync          Create missing projects and push all refs (default)
      --check         Report whether each mirror is current; no writes
  -n, --dry-run       Print the plan; create nothing, push nothing

Filters (from structure/repos.json):
  --type TYPE         Filter by type field (app|library|tool|config|template)
  --status STATUS     Filter by status (active|template|draft|wip|archived)
  --only NAME         Mirror a single repo by name
  --skip NAME         Exclude a repo (repeatable)
  --catalog PATH      Override path to repos.json

Options:
  --group PATH        GitLab group/namespace to mirror into (default: the GitHub org)
  --host URL          GitLab instance (default: https://gitlab.com)
  --visibility LEVEL  private|internal|public for created projects (default: private)
  --work-dir DIR      Where bare mirrors are cached between runs
  --fresh             Discard the cached mirror and re-clone from GitHub
  --no-prune          Keep GitLab refs that no longer exist on GitHub
  -h, --help          Show this help

Environment:
  GITLAB_TOKEN            Required. Personal/group access token with the
                          `api` and `write_repository` scopes.
  GH_TOKEN / GITHUB_TOKEN Optional. Only needed to read private source repos.
  GITLAB_HOST, GITLAB_GROUP, GITLAB_VISIBILITY, GITLAB_MIRROR_WORK_DIR
                          Defaults for the matching options.
  FLEET_ORG               GitHub org to mirror from (default: catalog organization).
  GITHUB_BASE             Source host (default: https://github.com).
  GITLAB_GIT_BASE         Git host, when it differs from the API host
                          (default: same as GITLAB_HOST).

Notes:
  * A GitLab project path may not start with a dot, so `.github` is mirrored as
    `dot-github`. Everything else keeps its GitHub name.
  * --no-prune is the safety valve: by default a ref deleted on GitHub is also
    deleted on GitLab, which is what makes this a mirror rather than a pile.
EOF
}

repos_reset_filters
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sync) MODE="sync"; shift ;;
    --check) MODE="check"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --type) FILTER_TYPE="${2:?Missing value for --type}"; shift 2 ;;
    --status) FILTER_STATUS="${2:?Missing value for --status}"; shift 2 ;;
    --only) FILTER_NAME="${2:?Missing value for --only}"; shift 2 ;;
    --skip) SKIPS+=("${2:?Missing value for --skip}"); shift 2 ;;
    --catalog) REPOS_JSON="${2:?Missing value for --catalog}"; shift 2 ;;
    --group) GITLAB_GROUP="${2:?Missing value for --group}"; shift 2 ;;
    --host) GITLAB_HOST="${2:?Missing value for --host}"; shift 2 ;;
    --visibility) VISIBILITY="${2:?Missing value for --visibility}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:?Missing value for --work-dir}"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --no-prune) PRUNE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in git curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

case "$VISIBILITY" in
  private|internal|public) ;;
  *) echo "Invalid --visibility: $VISIBILITY (expected private|internal|public)" >&2; exit 2 ;;
esac

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  cat >&2 <<EOF
GITLAB_TOKEN is not set.

Create a token at $GITLAB_HOST/-/user_settings/personal_access_tokens with the
"api" and "write_repository" scopes (or a group access token on the
$GITLAB_GROUP group with the Maintainer role), then:

  export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx

See doc/gitlab-mirror.md for the full setup.
EOF
  exit 1
fi

GITLAB_HOST="${GITLAB_HOST%/}"
GITHUB_BASE="${GITHUB_BASE%/}"
GITLAB_API="$GITLAB_HOST/api/v4"
# Git traffic normally goes to the same host as the API; overridable for
# self-hosted instances that split the two (and for the test harness).
GITLAB_GIT_BASE="${GITLAB_GIT_BASE:-$GITLAB_HOST}"
GITLAB_GIT_BASE="${GITLAB_GIT_BASE%/}"

# Keep the tokens out of process arguments (ps) and out of any config we leave
# on disk: curl reads its auth header from a 0600 config file, and git gets its
# Authorization header through GIT_CONFIG_* environment variables.
CURL_CFG="$(mktemp)"
chmod 600 "$CURL_CFG"
trap 'rm -f "$CURL_CFG"' EXIT
printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_TOKEN" >"$CURL_CFG"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

GITLAB_BASIC="$(b64 "oauth2:$GITLAB_TOKEN")"
GITHUB_BASIC=""
if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  GITHUB_BASIC="$(b64 "x-access-token:${GH_TOKEN:-${GITHUB_TOKEN}}")"
fi

# git, authenticated to GitLab for $GITLAB_HOST only.
gitlab_git() {
  GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.$GITLAB_HOST/.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: Basic $GITLAB_BASIC" \
    git "$@"
}

# git, authenticated to GitHub when a token is available (public repos need none).
github_git() {
  if [[ -n "$GITHUB_BASIC" ]]; then
    GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.$GITHUB_BASE/.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: Basic $GITHUB_BASIC" \
      git "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

# GitLab REST call. Sets API_BODY / API_CODE; returns non-zero on a non-2xx.
API_BODY=""
API_CODE=""
api() {
  local method="$1" path="$2" data="${3-}"
  local args=(-sS -X "$method" -K "$CURL_CFG" -w $'\n%{http_code}')
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi
  local raw
  if ! raw="$(curl "${args[@]}" "$GITLAB_API$path" 2>&1)"; then
    API_BODY="$raw"
    API_CODE="000"
    return 1
  fi
  API_CODE="${raw##*$'\n'}"
  API_BODY="${raw%$'\n'*}"
  [[ "$API_CODE" == 2* ]]
}

urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

api_error() {
  jq -r '(.message // .error // .) | if type == "string" then . else tojson end' <<<"$API_BODY" 2>/dev/null \
    || printf '%s' "$API_BODY"
}

# GitLab project paths may not start with a dot; everything else maps 1:1.
gitlab_path() {
  local name="$1"
  case "$name" in
    .*) printf 'dot-%s\n' "${name#.}" ;;
    *) printf '%s\n' "$name" ;;
  esac
}

is_skipped() {
  local name="$1" s
  for s in ${SKIPS[@]+"${SKIPS[@]}"}; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

github_url() { printf '%s/%s/%s.git\n' "$GITHUB_BASE" "$ORG" "$1"; }
gitlab_url() { printf '%s/%s/%s.git\n' "$GITLAB_GIT_BASE" "$GITLAB_GROUP" "$1"; }

# Resolve the group once, so a typo in --group fails before touching any repo.
GROUP_ID=""
resolve_group() {
  if ! api GET "/groups/$(urlenc "$GITLAB_GROUP")"; then
    echo "Cannot read GitLab group '$GITLAB_GROUP' on $GITLAB_HOST (HTTP $API_CODE): $(api_error)" >&2
    echo "Check GITLAB_TOKEN's scopes and that the group path is exact (it is case-sensitive)." >&2
    exit 1
  fi
  GROUP_ID="$(jq -r '.id' <<<"$API_BODY")"
}

# Create the GitLab project if it is missing. Echoes created|present|would-create.
ensure_project() {
  local name="$1" path="$2" display="$3" description="$4"

  if api GET "/projects/$(urlenc "$GITLAB_GROUP/$path")"; then
    printf 'present\n'
    return 0
  fi
  if [[ "$API_CODE" != "404" ]]; then
    echo "  lookup failed (HTTP $API_CODE): $(api_error)" >&2
    return 1
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'would-create\n'
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg name "$display" \
    --arg path "$path" \
    --argjson namespace_id "$GROUP_ID" \
    --arg visibility "$VISIBILITY" \
    --arg description "$description" \
    '{
      name: $name,
      path: $path,
      namespace_id: $namespace_id,
      visibility: $visibility,
      description: $description,
      # Backup only: no issue tracker, no merge requests, no CI, no Pages.
      issues_access_level: "disabled",
      merge_requests_access_level: "disabled",
      builds_access_level: "disabled",
      wiki_access_level: "disabled",
      snippets_access_level: "disabled",
      pages_access_level: "disabled",
      container_registry_access_level: "disabled",
      packages_enabled: false,
      lfs_enabled: true,
      initialize_with_readme: false
    }')"

  if ! api POST "/projects" "$payload"; then
    echo "  create failed (HTTP $API_CODE): $(api_error)" >&2
    return 1
  fi
  printf 'created\n'
}

# GitLab protects the default branch the first time it is pushed, and a
# protected branch rejects exactly the operations a mirror needs: force updates
# after a rewritten history, and deletion of a branch removed upstream. The
# mirror is a copy, not a place anyone works, so clear protection instead.
clear_protection() {
  local path="$1" enc
  enc="$(urlenc "$GITLAB_GROUP/$path")"
  api GET "/projects/$enc/protected_branches" || return 0
  local branch
  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    api DELETE "/projects/$enc/protected_branches/$(urlenc "$branch")" >/dev/null 2>&1 || true
  done < <(jq -r '.[]?.name // empty' <<<"$API_BODY" 2>/dev/null)
}

# Point the GitLab project's default branch at the source repo's default.
set_default_branch() {
  local path="$1" branch="$2"
  [[ -n "$branch" ]] || return 0
  if ! api GET "/projects/$(urlenc "$GITLAB_GROUP/$path")"; then
    return 0
  fi
  local current
  current="$(jq -r '.default_branch // ""' <<<"$API_BODY")"
  [[ "$current" == "$branch" ]] && return 0
  api PUT "/projects/$(urlenc "$GITLAB_GROUP/$path")" \
    "$(jq -n --arg b "$branch" '{default_branch: $b}')" >/dev/null 2>&1 || true
}

# Prepare (or refresh) the cached bare mirror and fetch from GitHub.
fetch_mirror() {
  local dir="$1" url="$2"

  if [[ $FRESH -eq 1 && -d "$dir" ]]; then
    rm -rf "$dir"
  fi
  if [[ ! -d "$dir" ]]; then
    git init --quiet --bare "$dir"
  fi
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" remote set-url origin "$url"

  # Explicit refspecs instead of `clone --mirror`: GitHub also advertises
  # refs/pull/*, and a backup has no use for pull-request refs.
  git -C "$dir" config --unset-all remote.origin.fetch >/dev/null 2>&1 || true
  git -C "$dir" config --add remote.origin.fetch '+refs/heads/*:refs/heads/*'
  git -C "$dir" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'

  github_git -C "$dir" fetch --quiet --force --prune --prune-tags origin
}

# Default branch of the source repo, e.g. "main".
source_default_branch() {
  local dir="$1"
  github_git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }'
}

ref_count() { git -C "$1" for-each-ref --format='%(refname)' refs/heads refs/tags | wc -l | tr -d ' '; }

# Remote ref listing (sha + name), sorted, for --check comparisons.
remote_refs() {
  local which="$1" url="$2"
  if [[ "$which" == "gitlab" ]]; then
    gitlab_git ls-remote --heads --tags "$url" 2>/dev/null
  else
    github_git ls-remote --heads --tags "$url" 2>/dev/null
  fi | sort
}

total=0 created=0 pushed=0 uptodate=0 failed=0 stale=0 missing=0

check_repo() {
  local name="$1" path="$2"
  local gh gl
  gh="$(remote_refs github "$(github_url "$name")")" || true
  gl="$(remote_refs gitlab "$(gitlab_url "$path")")" || true

  if [[ -z "$gh" ]]; then
    echo "  SKIPPED — cannot read $(github_url "$name") (empty repo, or no access)"
    failed=$((failed + 1))
    return 0
  fi
  if [[ -z "$gl" ]]; then
    echo "  MISSING — no mirror at $(gitlab_url "$path")"
    missing=$((missing + 1))
    return 0
  fi
  if [[ "$gh" == "$gl" ]]; then
    echo "  in sync ($(printf '%s\n' "$gh" | grep -c . || true) ref(s))"
    uptodate=$((uptodate + 1))
    return 0
  fi
  local diff_count
  diff_count="$(comm -3 <(printf '%s\n' "$gh") <(printf '%s\n' "$gl") | grep -c . || true)"
  echo "  STALE — $diff_count ref(s) differ from GitHub"
  stale=$((stale + 1))
}

sync_repo() {
  local name="$1" path="$2" display="$3" description="$4"
  local dir="$WORK_DIR/$name.git"
  local state

  if ! state="$(ensure_project "$name" "$path" "$display" "$description")"; then
    failed=$((failed + 1))
    return 0
  fi
  case "$state" in
    created) echo "  created $(gitlab_url "$path")"; created=$((created + 1)) ;;
    would-create) echo "  [dry-run] would create $(gitlab_url "$path") ($VISIBILITY)" ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would mirror $(github_url "$name") -> $(gitlab_url "$path")"
    return 0
  fi

  if ! fetch_mirror "$dir" "$(github_url "$name")"; then
    echo "  fetch failed: $(github_url "$name")" >&2
    failed=$((failed + 1))
    return 0
  fi

  clear_protection "$path"

  local push_args=(push --porcelain)
  [[ $PRUNE -eq 1 ]] && push_args+=(--prune)
  push_args+=("$(gitlab_url "$path")" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*')

  local out
  if ! out="$(gitlab_git -C "$dir" "${push_args[@]}" 2>&1)"; then
    echo "  push failed: $(printf '%s' "$out" | tail -n 3)" >&2
    if printf '%s' "$out" | grep -qi 'protected branch'; then
      echo "  hint: the token needs the Maintainer role, or set the group's" >&2
      echo "        default branch protection to 'Not protected' (see doc/gitlab-mirror.md)." >&2
    fi
    failed=$((failed + 1))
    return 0
  fi

  local changed
  changed="$(printf '%s\n' "$out" | grep -cE "^[*+ -]"$'\t' || true)"
  if [[ "$changed" -gt 0 ]]; then
    echo "  pushed $changed ref update(s) — $(ref_count "$dir") ref(s) mirrored"
    pushed=$((pushed + 1))
  else
    echo "  up to date — $(ref_count "$dir") ref(s) mirrored"
    uptodate=$((uptodate + 1))
  fi

  set_default_branch "$path" "$(source_default_branch "$dir")"
}

resolve_group

if [[ "$MODE" == "sync" && $DRY_RUN -eq 0 ]]; then
  mkdir -p "$WORK_DIR"
fi

echo "GitHub $ORG -> GitLab $GITLAB_HOST/$GITLAB_GROUP (git data only)"
[[ "$MODE" == "sync" && $DRY_RUN -eq 0 ]] && echo "Mirror cache: $WORK_DIR"
echo

while IFS= read -r repo; do
  name="$(jq -r '.name' <<<"$repo")"
  if is_skipped "$name"; then
    echo "==== $name (skipped) ===="
    continue
  fi
  total=$((total + 1))
  path="$(gitlab_path "$name")"
  display="$(jq -r '.displayName // .name' <<<"$repo")"
  description="Backup mirror of $GITHUB_BASE/$ORG/$name — git history only; issues, merge requests, and CI live on GitHub."

  echo "==== $name -> $GITLAB_GROUP/$path ===="
  if [[ "$MODE" == "check" ]]; then
    check_repo "$name" "$path"
  else
    sync_repo "$name" "$path" "$display" "$description"
  fi
done < <(repos_filtered_json_lines)

echo "----"
if [[ "$MODE" == "check" ]]; then
  echo "Summary: $total repo(s) — $uptodate in sync, $stale stale, $missing missing, $failed unreadable."
  [[ $((stale + missing + failed)) -eq 0 ]]
else
  echo "Summary: $total repo(s) — $created created, $pushed updated, $uptodate up to date, $failed failed."
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry-run only — re-run without --dry-run to create projects and push."
  fi
  [[ $failed -eq 0 ]]
fi
