#!/usr/bin/env bash
# fm-ci-watch.sh - idempotent poller that turns a new failed GitHub Actions run
# on a watched repository's default branch into an inbox entry, so a red
# default branch reaches the supervisor instead of waiting for a lane to poll.
#
# Made to run on a schedule (docs/configuration.md "CI failure watch" installs
# the systemd user timer shipped in docs/examples/systemd/), and
# safe to run by hand: a run that finds nothing new changes nothing.
#
# Per repository in scope it lists
#   gh run list -R <repo> --branch <default> --status failure --limit N
# and delivers every run whose databaseId is not in that repository's seen
# set. Delivery of one failure is:
#
#   1. a firstmate note through `bin/fm-inbox.sh note` (unless --no-note),
#      which queues the durable record and wakes firstmate, and
#   2. when the repository has one, an entry in its own agent-context INBOX
#      (see Configuration for the lookup). fm-inbox addresses the firstmate
#      home, not a repository, so this per-repository copy is written here.
#      The entry is inserted newest-first (after an H1 preamble when the file
#      has one) and carries a `fm-ci-watch run=<id>` marker, so a retried
#      delivery never writes the same failure twice.
#
# Only a delivered run is added to the seen set; a run whose delivery failed is
# retried on the next poll.
#
# First run: when a repository has no seen set yet, every failure listed now is
# recorded as seen, and only those created in the last 24 hours are delivered.
# Enabling the watcher never floods the inbox with history.
#
# State (under the home's state/ directory):
#   state/ci-watch/<owner>__<name>.seen   run databaseIds, one per line, the
#                                         newest 1000 kept; replaced atomically
#   state/ci-watch/.lock/                 single-run lock (pid inside)
#
# Failure handling: a gh error (auth, network, rate limit) or unparseable output
# for a repository leaves that repository's seen set untouched, the others are
# still polled, and the script exits 1. A scope that cannot be resolved exits
# before any state is read or written. A concurrent run exits 0 and does
# nothing.
#
# Usage:
#   fm-ci-watch.sh [--dry-run] [--no-note] [--limit N] [scope-token...]
#
#   --dry-run   print what would be delivered; write nothing.
#   --no-note   skip the fm-inbox note; write only the repository INBOX.
#   --limit N   failed runs listed per repository (default 50).
#
# Scope tokens and their configuration are owned by bin/fm-ci-lib.sh
# (`org:<owner>`, `<owner>/<name>`, FM_CI_SCOPE, config/ci-watch-scope).
#
# Configuration (config/ in the home, or the environment):
#   config/ci-watch-inbox-root  FM_CI_INBOX_ROOT  directory holding the
#       per-repository checkouts whose agent-context/INBOX.md receives entries.
#       A repository is matched by its name, then its lowercased name; one
#       with no checkout there goes to <root>/agent-context/INBOX.md if that
#       exists. Unset means the fm-inbox note is the only delivery.
#   config/ci-watch-inbox-map   `<owner>/<name> <path-to-INBOX.md>` lines that
#       override that lookup for a repository whose checkout is named
#       differently.
#
# Environment:
#   FM_HOME              operational home whose state/ and config/ are used.
#   FM_STATE_OVERRIDE    alternative state directory (tests).
#   FM_CI_NOW            epoch seconds to use as "now" (tests).
#
# Requires gh (authenticated) and jq.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH_DIR="$STATE/ci-watch"
SEEN_KEEP=1000
FIRST_RUN_WINDOW=86400

# shellcheck source=bin/fm-ci-lib.sh
. "$SELF_DIR/fm-ci-lib.sh"

log() { printf 'fm-ci-watch: %s\n' "$*" >&2; }
die() { log "$1"; exit "${2:-1}"; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

dry_run=0
note=1
limit=50
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=1; shift ;;
    --no-note) note=0; shift ;;
    --limit) [ "$#" -ge 2 ] || die "--limit needs a value" 2; limit=$2; shift 2 ;;
    --) shift; args+=("$@"); break ;;
    -*) die "unknown option: $1 (try --help)" 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$limit" in ''|*[!0-9]*) die "--limit must be a positive integer" 2 ;; esac

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

inbox_root="${FM_CI_INBOX_ROOT-$(fm_ci_read_setting ci-watch-inbox-root)}"
case "$inbox_root" in "~"/*) inbox_root="$HOME/${inbox_root#"~/"}" ;; esac
now=${FM_CI_NOW:-$(date +%s)}

# Resolve the whole scope before touching state: a watcher that cannot list its
# scope must not decide anything about the repositories it did list.
rc=0
scope=$(fm_ci_resolve_scope "${args[@]+"${args[@]}"}") || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ -n "$scope" ] || die "the scope resolved to no repositories"

if [ "$dry_run" -eq 0 ]; then
  mkdir -p "$WATCH_DIR"
  if ! mkdir "$WATCH_DIR/.lock" 2>/dev/null; then
    holder=$(cat "$WATCH_DIR/.lock/pid" 2>/dev/null || true)
    if { [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; } ||
      { [ -z "$holder" ] && [ -z "$(find "$WATCH_DIR/.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; }; then
      log "another run (pid ${holder:-starting}) holds $WATCH_DIR/.lock; nothing to do"
      exit 0
    fi
    # The holder is gone, or never wrote its pid within ten minutes: stale.
    rm -rf "$WATCH_DIR/.lock"
    mkdir "$WATCH_DIR/.lock" || die "could not take $WATCH_DIR/.lock"
  fi
  printf '%s\n' "$$" >"$WATCH_DIR/.lock/pid"
  trap 'rm -rf "$WATCH_DIR/.lock"' EXIT
fi

# The INBOX.md a repository's failures go to, or nothing: an explicit
# config/ci-watch-inbox-map line, else <root>/<name>/agent-context/INBOX.md
# (the name as GitHub spells it, then lowercased), else the workspace inbox.
inbox_for() {  # <owner/name>
  local repo=$1 name=${1#*/} lower mapped dir
  mapped=$(fm_ci_read_config_lines ci-watch-inbox-map | awk -v r="$repo" '$1 == r { print $2; exit }')
  case "$mapped" in "~"/*) mapped="$HOME/${mapped#"~/"}" ;; esac
  if [ -n "$mapped" ]; then
    printf '%s\n' "$mapped"
    return 0
  fi
  [ -n "$inbox_root" ] || return 0
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  for dir in "$inbox_root/$name" "$inbox_root/$lower"; do
    if [ -d "$dir/agent-context" ]; then
      printf '%s\n' "$dir/agent-context/INBOX.md"
      return 0
    fi
  done
  if [ -f "$inbox_root/agent-context/INBOX.md" ]; then
    printf '%s\n' "$inbox_root/agent-context/INBOX.md"
  fi
}

# Insert <entry-file> into <inbox> newest-first, atomically.
write_inbox_entry() {  # <inbox> <run-ids> <entry-file>
  local inbox=$1 entry=$3 tmp
  tmp=$(mktemp "$(dirname "$inbox")/.INBOX.md.fm-ci-watch.XXXXXX") || return 1
  if [ -f "$inbox" ]; then
    # After an H1 preamble, before the first H2; at the top when there is no
    # H1; at the end when an H1 file has no H2 yet.
    awk -v entry="$entry" '
      function emit() { while ((getline l < entry) > 0) print l; close(entry); print ""; done = 1 }
      NR == 1 && !/^# / { emit() }
      !done && NR > 1 && /^## / { emit() }
      { print }
      END { if (!done) { print ""; emit() } }
    ' "$inbox" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$(stat -c %a "$inbox" 2>/dev/null || stat -f %Lp "$inbox")" "$tmp" 2>/dev/null || true
  else
    cat "$entry" >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$inbox"
}

# Deliver the new failures of one workflow (a compact JSON array, oldest
# first) as one INBOX entry and one note. Returns non-zero on failure.
deliver() {  # <repo> <branch> <runs-json>
  local repo=$1 branch=$2 group=$3 workflow count latest sha event url at summary inbox entry out ids id fresh=""
  workflow=$(jq -r '.[0].workflowName' <<<"$group")
  count=$(jq -r 'length' <<<"$group")
  latest=$(jq -c '.[-1]' <<<"$group")
  sha=$(jq -r '.headSha[0:7]' <<<"$latest")
  event=$(jq -r '.event' <<<"$latest")
  url=$(jq -r '.url' <<<"$latest")
  at=$(jq -r '.updatedAt' <<<"$latest")
  ids=$(jq -r '.[].databaseId' <<<"$group")
  summary="CI failed: $repo $workflow on $branch ($sha, $event) at $at - $url"
  [ "$count" -eq 1 ] || summary="$summary (+$((count - 1)) earlier new failure(s) of this workflow)"
  inbox=$(inbox_for "$repo")

  if [ "$dry_run" -eq 1 ]; then
    printf 'would deliver %s%s\n' "$summary" "${inbox:+ -> $inbox}"
    return 0
  fi

  if [ -n "$inbox" ]; then
    # Runs a previous, partly failed delivery already wrote are not rewritten.
    for id in $ids; do
      [ -f "$inbox" ] && grep -qF "fm-ci-watch run=$id " "$inbox" && continue
      fresh="$fresh$id "
    done
  fi
  if [ -n "$fresh" ]; then
    entry=$(mktemp "${TMPDIR:-/tmp}/fm-ci-watch-entry.XXXXXX")
    # shellcheck disable=SC2016  # The backticks are Markdown code spans.
    {
      # U+1F534 and U+2014 match the INBOX heading convention.
      printf '## \360\237\224\264 %s \342\200\224 CI failed: %s on `%s` (%s)\n' "${at:0:10}" "$workflow" "$branch" "$repo"
      for id in $fresh; do printf '<!-- fm-ci-watch run=%s -->\n' "$id"; done
      printf -- '- Repository: %s\n' "$repo"
      printf -- '- Workflow: %s (event `%s`)\n' "$workflow" "$event"
      printf -- '- Branch: `%s`, commit `%s`\n' "$branch" "$sha"
      printf -- '- Run: %s\n' "$url"
      printf -- '- Failed at: %s\n' "$at"
      if [ "$count" -gt 1 ]; then
        printf -- '- Earlier new failures of this workflow since the last poll:\n'
        jq -r '.[:-1][] | "  - \(.updatedAt) `\(.headSha[0:7])` \(.url)"' <<<"$group"
      fi
      printf '\nReported by `fm-ci-watch.sh`; not yet triaged.\n'
    } >"$entry"
    if ! write_inbox_entry "$inbox" "$fresh" "$entry"; then
      rm -f "$entry"
      log "$repo: could not write $workflow failures into $inbox"
      return 1
    fi
    rm -f "$entry"
  fi

  if [ "$note" -eq 1 ]; then
    # A saved note counts as delivered even when its wake failed: the record is
    # durable and firstmate reads it at its next drain. Retrying would only
    # queue a duplicate note.
    out=$("$SELF_DIR/fm-inbox.sh" note "$summary" 2>&1) || true
    case "$out" in
      queued\ *) ;;
      *) log "$repo: fm-inbox note for $workflow failed: $out"; return 1 ;;
    esac
    case "$out" in
      *"NOT woken"*|*"NOT announced"*) log "$repo: note for $workflow saved but firstmate was not woken" ;;
    esac
  fi
  printf 'delivered %s\n' "$summary"
}

gh_err=$(mktemp "${TMPDIR:-/tmp}/fm-ci-watch-gh.XXXXXX")
if [ "$dry_run" -eq 0 ]; then
  trap 'rm -rf "$WATCH_DIR/.lock" "$gh_err"' EXIT
else
  trap 'rm -f "$gh_err"' EXIT
fi

fields=databaseId,workflowName,headBranch,headSha,event,createdAt,updatedAt,url,attempt
errors=0
while IFS=$'\t' read -r repo branch; do
  seen_file="$WATCH_DIR/${repo%%/*}__${repo#*/}.seen"
  if ! runs=$(gh run list -R "$repo" --branch "$branch" --status failure --limit "$limit" --json "$fields" 2>"$gh_err") ||
    ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$runs"; then
    log "$repo: could not list failed runs: $(cat "$gh_err" - <<<"$runs" | head -c 300 | tr '\n' ' ')"
    errors=$((errors + 1))
    continue
  fi

  first=0
  [ -f "$seen_file" ] || first=1
  seen=""
  [ "$first" -eq 1 ] || seen=$(cat "$seen_file")

  # Undelivered runs grouped per workflow, oldest first. On a first run, only
  # the last 24 hours.
  pending=$(jq -c --arg seen "$seen" --argjson first "$first" \
    --argjson cutoff "$((now - FIRST_RUN_WINDOW))" '
      ($seen | split("\n") | map(select(. != "")) | map({key: ., value: true}) | from_entries) as $s
      | map(select(($s[(.databaseId | tostring)] // false) | not))
      | if $first == 1 then map(select((.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $cutoff)) else . end
      | group_by(.workflowName) | map(sort_by(.createdAt)) | sort_by(.[-1].createdAt)[]' <<<"$runs")

  delivered=""
  failed=0
  while IFS= read -r group; do
    [ -n "$group" ] || continue
    if deliver "$repo" "$branch" "$group"; then
      delivered="$delivered$(jq -r '.[].databaseId' <<<"$group")"$'\n'
    else
      failed=1
      break
    fi
  done <<<"$pending"

  [ "$dry_run" -eq 0 ] || continue

  # The new seen set: the old one, plus what was delivered, plus on a first run
  # everything listed now that was deliberately not delivered (older than 24h).
  # A failed delivery keeps the rest pending, so on a first run it only records
  # the old history, never an undelivered recent failure.
  {
    [ -z "$seen" ] || printf '%s\n' "$seen"
    printf '%s' "$delivered"
    if [ "$first" -eq 1 ]; then
      jq -r --argjson cutoff "$((now - FIRST_RUN_WINDOW))" \
        '.[] | select((.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $cutoff) | .databaseId' <<<"$runs"
    fi
  } | awk 'NF && !seen[$0]++' | tail -n "$SEEN_KEEP" >"$seen_file.tmp.$$"
  mv "$seen_file.tmp.$$" "$seen_file"

  if [ "$failed" -eq 1 ]; then
    errors=$((errors + 1))
  fi
done <<<"$scope"

[ "$errors" -eq 0 ] || exit 1
