#!/usr/bin/env bash
# Parse structure/repos.json for tooling and AI agents.
#
# Examples:
#   parse-repos.sh names
#   parse-repos.sh names --type library
#   parse-repos.sh list --format json --type library
#   parse-repos.sh get pycd48
#   parse-repos.sh paths --type library --require-local
#   parse-repos.sh for-each --type library -- echo "$REPO_NAME $REPO_HOMEPAGE"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"

usage() {
  cat <<'EOF'
Usage: parse-repos.sh <command> [options]

Commands:
  names              Print repository names
  get NAME           Print one repository as JSON
  list               List repositories
  paths              Print local workspace paths
  for-each           Run a command for each repo (sets REPO_* env vars)
  summary            Print catalog summary

Options:
  --type TYPE        Filter by repos.json type field (app|library|tool|config|template)
  --status STATUS    Filter by status field (active|template|draft|wip|archived)
  --catalog PATH     Override path to repos.json
  --format FORMAT    list output: text, tsv, json, names (default: text)
  --fields FIELDS    Comma-separated fields for text/tsv list output
  --require-local    paths: only print paths that exist on disk
  -h, --help         Show this help

Environment:
  REPOS_JSON              Path to structure/repos.json
  FLEET_WORKSPACE         Workspace root containing member repos
EOF
}

COMMAND=""
FORMAT="text"
FIELDS=""
GET_NAME=""
FOR_EACH_CMD=()

consume_filter_arg() {
  case "$1" in
    --type)
      FILTER_TYPE="${2:?Missing value for --type}"
      ;;
    --status)
      FILTER_STATUS="${2:?Missing value for --status}"
      ;;
    --catalog)
      REPOS_JSON="${2:?Missing value for --catalog}"
      ;;
    --require-local)
      REQUIRE_LOCAL=1
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

shift_parsed_filter_arg() {
  case "$1" in
    --type|--status|--catalog)
      echo 2
      ;;
    *)
      echo 1
      ;;
  esac
}

parse_global_args() {
  repos_reset_filters
  while [[ $# -gt 0 ]]; do
    case "$1" in
      names|get|list|paths|for-each|summary)
        COMMAND="$1"
        shift
        break
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$COMMAND" ]]; then
    usage >&2
    exit 2
  fi

  if [[ "$COMMAND" == "get" && $# -gt 0 && "$1" != --* ]]; then
    GET_NAME="$1"
    shift
  fi

  if [[ "$COMMAND" == "for-each" ]]; then
    while [[ $# -gt 0 && "$1" != "--" ]]; do
      consume_filter_arg "$@" || {
        echo "Unknown option for for-each: $1" >&2
        exit 2
      }
      shift "$(shift_parsed_filter_arg "$1")"
    done
    [[ "${1:-}" == "--" ]] && shift
    FOR_EACH_CMD=("$@")
    return
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        FORMAT="${2:?Missing value for --format}"
        shift 2
        ;;
      --fields)
        FIELDS="${2:?Missing value for --fields}"
        shift 2
        ;;
      --type|--status|--catalog|--require-local)
        consume_filter_arg "$@" || {
          echo "Unknown option: $1" >&2
          exit 2
        }
        shift "$(shift_parsed_filter_arg "$1")"
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
}

print_list_text() {
  local default_fields="name,type,status,description,githubHomepage,localExists"
  local fields="${FIELDS:-$default_fields}"
  local field value
  IFS=',' read -r -a field_array <<<"$fields"

  while IFS= read -r repo; do
    if [[ "$FORMAT" == "tsv" ]]; then
      local values=()
      for field in "${field_array[@]}"; do
        if [[ "$field" == "localExists" ]]; then
          value="$(jq -r '.localExists' <<<"$repo")"
        else
          value="$(jq -r --arg field "$field" '.[$field] // "" | if type == "array" then join(",") else tostring end' <<<"$repo")"
        fi
        values+=("$value")
      done
      local IFS=$'\t'
      echo "${values[*]}"
    else
      local parts=()
      for field in "${field_array[@]}"; do
        if [[ "$field" == "localExists" ]]; then
          value="$(jq -r '.localExists' <<<"$repo")"
        else
          value="$(jq -r --arg field "$field" '.[$field] // "" | if type == "array" then join(",") else tostring end' <<<"$repo")"
        fi
        parts+=("${field}=${value}")
      done
      local IFS=' | '
      echo "${parts[*]}"
    fi
  done < <(repos_filtered_json_lines | repos_add_local_exists)
}

main() {
  parse_global_args "$@"

  case "$COMMAND" in
    names)
      repos_names
      ;;
    get)
      if [[ -z "$GET_NAME" ]]; then
        echo "get requires a repository name" >&2
        exit 2
      fi
      repos_get "$GET_NAME"
      ;;
    list)
      case "$FORMAT" in
        json)
          repos_list_json
          ;;
        names)
          repos_names
          ;;
        text|tsv)
          print_list_text
          ;;
        *)
          echo "Unknown format: $FORMAT" >&2
          exit 2
          ;;
      esac
      ;;
    paths)
      repos_paths
      ;;
    for-each)
      if [[ ${#FOR_EACH_CMD[@]} -eq 0 ]]; then
        echo "for-each requires a command after --" >&2
        exit 2
      fi
      repos_for_each "${FOR_EACH_CMD[@]}"
      ;;
    summary)
      repos_summary
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
