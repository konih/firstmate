#!/usr/bin/env bash
# fm-ci-lib.sh - shared scope resolution and GitHub Actions run helpers for
# bin/fm-ci-rescan.sh and bin/fm-ci-watch.sh. Sourced, never executed.
#
# Scope. Which repositories to watch is one captain's account choice, so this
# file carries no default. The scope comes from, in order of precedence:
#
#   1. the caller's positional arguments,
#   2. FM_CI_SCOPE (whitespace-separated tokens),
#   3. config/ci-watch-scope in the home (one token per line, # comments).
#
# A token is either `org:<owner>` (every non-archived repository the owner has,
# up to 100) or `<owner>/<name>` (one repository). Archived and empty
# repositories are skipped, because they have no default branch to watch.
#
# fm_ci_resolve_scope prints one `<owner>/<name><TAB><default-branch>` line per
# repository, deduplicated in first-seen order. It returns non-zero, having
# printed nothing, when no scope is configured or when any gh call fails: a
# partial scope would make a watcher silently stop watching the repositories it
# could not list.
#
# Environment:
#   FM_HOME              operational home whose config/ holds ci-watch-scope.
#   FM_CONFIG_OVERRIDE   alternative config directory (tests).
#   FM_CI_SCOPE          scope tokens; overrides the config file.
#
# Requires gh and jq on PATH.

fm_ci_config_dir() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$root}/config}"
}

# Non-comment, non-blank lines of config/<name>, trimmed, one per line.
fm_ci_read_config_lines() {  # <file-name>
  local path line
  path="$(fm_ci_config_dir)/$1"
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] && printf '%s\n' "$line"
  done <"$path"
  return 0
}

# First config line of config/<name>, or nothing.
fm_ci_read_setting() {  # <file-name>
  fm_ci_read_config_lines "$1" | head -n 1
}

fm_ci_scope_tokens() {  # [token...]
  local tok
  if [ "$#" -gt 0 ]; then
    for tok in "$@"; do printf '%s\n' "$tok"; done
  elif [ -n "${FM_CI_SCOPE:-}" ]; then
    # shellcheck disable=SC2086
    for tok in $FM_CI_SCOPE; do printf '%s\n' "$tok"; done
  else
    fm_ci_read_config_lines ci-watch-scope
  fi
}

fm_ci_resolve_scope() {  # [token...]
  local tokens tok out rows=""
  tokens=$(fm_ci_scope_tokens "$@")
  if [ -z "$tokens" ]; then
    printf 'fm-ci: no scope: pass <owner>/<name> or org:<owner> arguments, set FM_CI_SCOPE, or write one token per line into %s/ci-watch-scope\n' \
      "$(fm_ci_config_dir)" >&2
    return 2
  fi
  while IFS= read -r tok; do
    case "$tok" in
      org:?*)
        out=$(gh repo list "${tok#org:}" --limit 100 \
          --json nameWithOwner,isArchived,isEmpty,defaultBranchRef \
          --jq '.[] | select((.isArchived | not) and (.isEmpty | not) and ((.defaultBranchRef.name // "") != ""))
                    | [.nameWithOwner, .defaultBranchRef.name] | @tsv') || {
          printf 'fm-ci: could not list repositories of %s\n' "${tok#org:}" >&2
          return 1
        }
        ;;
      ?*/?*)
        out=$(gh repo view "$tok" \
          --json nameWithOwner,isArchived,isEmpty,defaultBranchRef \
          --jq 'select((.isArchived | not) and (.isEmpty | not) and ((.defaultBranchRef.name // "") != ""))
                | [.nameWithOwner, .defaultBranchRef.name] | @tsv') || {
          printf 'fm-ci: could not read repository %s\n' "$tok" >&2
          return 1
        }
        ;;
      *)
        printf 'fm-ci: bad scope token %s (want org:<owner> or <owner>/<name>)\n' "$tok" >&2
        return 2
        ;;
    esac
    [ -z "$out" ] || rows="$rows$out"$'\n'
  done <<<"$tokens"
  printf '%s' "$rows" | awk -F '\t' 'NF == 2 && !seen[$1]++'
}
