#!/usr/bin/env bash
# Sync GitHub repository description, homepage, topics, and template flag from
# structure/repos.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"

ORG="${FLEET_ORG:-${OPENPHYSICS_ORG:-$(repos_org)}}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sync-github-metadata.sh [options]

Update GitHub repo description, website URL, topics, and template flag using
structure/repos.json.

Catalog rows with `"type": "template"` also get `gh repo edit --template` so
"Use this template" stays enabled.

Description:
  Prefer shortDescription when set; otherwise description. GitHub caps at 350
  characters (truncate with a warning if needed).

Topics:
  githubTopics from the catalog row, plus a kebab-case topic per entry in
  `language`. Topics are replaced (catalog is source of truth); a row with no
  githubTopics and no language leaves topics untouched. GitHub caps topics at 20.

Options:
  --dry-run          Print planned changes without calling gh
  --type TYPE        Only repositories of this type (app|library|tool|config|template)
  --repo NAME        Sync a single repository
  -h, --help         Show this help

Requires: gh auth login with repo scope, jq installed.
EOF
}

REPO_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --type)
      FILTER_TYPE="${2:?Missing value for --type}"
      shift 2
      ;;
    --repo)
      REPO_NAME="${2:?Missing value for --repo}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

repos_require_jq

if [[ -n "$REPO_NAME" ]]; then
  FILTER_NAME="$REPO_NAME"
fi

repos_json="$(repos_list_json)"
FILTER_NAME=""

# Build GitHub topic names for a catalog row. Prints nothing to skip.
topics_json_for_repo() {
  local repo="$1"
  # Apostrophe stripped via \u0027 so this jq program stays single-quote-safe in bash.
  jq -c '
    def slug:
      ascii_downcase
      | gsub("\u0027"; "")
      | gsub("[^a-z0-9]+"; "-")
      | gsub("^-+"; "")
      | gsub("-+$"; "")
      | .[0:50];
    def uniq:
      reduce .[] as $x ([]; if index($x) then . else . + [$x] end);
    (
      [(.language // [])[] | slug | select(length > 0)]
      + [(.githubTopics // [])[]]
    ) as $topics
    | if ($topics | length) > 0 then $topics | uniq | .[0:20] else empty end
  ' <<<"$repo"
}

github_description_for_repo() {
  local repo="$1"
  jq -r '
    if ((.shortDescription // "") | length) > 0 then .shortDescription
    else .description // ""
    end
  ' <<<"$repo"
}

put_topics() {
  local name="$1"
  local topics_json="$2"
  # PUT /repos/{owner}/{repo}/topics replaces the full topic set.
  jq -n --argjson names "$topics_json" '{names: $names}' \
    | gh api -X PUT "repos/$ORG/$name/topics" --input - >/dev/null
}

count=0
while IFS= read -r repo; do
  name="$(jq -r '.name' <<<"$repo")"
  description="$(github_description_for_repo "$repo")"
  homepage="$(jq -r '.githubHomepage // ""' <<<"$repo")"
  repo_type="$(jq -r '.type // ""' <<<"$repo")"
  topics_json="$(topics_json_for_repo "$repo" || true)"

  echo "$name: homepage=${homepage:-"(none)"}"
  if [[ -n "$description" ]]; then
    if [[ ${#description} -le 80 ]]; then
      echo "  description: $description"
    else
      echo "  description: ${description:0:77}..."
    fi
  fi
  if [[ -n "$topics_json" ]]; then
    echo "  topics: $(jq -r 'join(", ")' <<<"$topics_json")"
  fi
  if [[ "$repo_type" == "template" ]]; then
    echo "  template: ensure is_template=true"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  dry-run: gh repo edit $ORG/$name ..."
    if [[ -n "$topics_json" ]]; then
      echo "  dry-run: PUT repos/$ORG/$name/topics"
    fi
    count=$((count + 1))
    continue
  fi

  cmd=(gh repo edit "$ORG/$name")
  if [[ -n "$description" ]]; then
    # GitHub caps repository descriptions at 350 characters.
    if [[ ${#description} -gt 350 ]]; then
      truncated="${description:0:347}"
      truncated="${truncated% *}..."
      echo "  warning: description is ${#description} chars; truncating to ${#truncated} for GitHub" >&2
      description="$truncated"
    fi
    cmd+=(--description "$description")
  fi
  if [[ -n "$homepage" ]]; then
    cmd+=(--homepage "$homepage")
  fi
  # Catalog type "template" must stay a GitHub template repo (Use this template).
  if [[ "$repo_type" == "template" ]]; then
    cmd+=(--template)
  fi

  if ! "${cmd[@]}"; then
    exit 1
  fi

  if [[ -n "$topics_json" ]]; then
    if ! put_topics "$name" "$topics_json"; then
      echo "  error: failed to update topics for $ORG/$name" >&2
      exit 1
    fi
  fi

  count=$((count + 1))
done < <(jq -c '.[]' <<<"$repos_json")

echo "Synced $count repositories."
