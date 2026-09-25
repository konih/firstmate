#!/usr/bin/env bash
# fm-ci-rescan.sh - one-shot survey of GitHub Actions health across a scope of
# repositories, printed as a Markdown report.
#
# For each repository it reads the last runs on the default branch
# (`gh run list --branch <default> --limit <N>`) and computes, per workflow:
#
#   runs          completed runs in the window
#   failures      runs concluding failure, timed_out or startup_failure
#   failure rate  failures / (failures + successes); cancelled and skipped
#                 runs are neither
#   time-to-green median time from the end of the first failing run of a red
#                 streak to the end of the next successful run of the same
#                 workflow on the same branch
#   red now       the latest decisive run failed and nothing has fixed it yet
#
# It also flags flaky candidates: a workflow that both failed and passed on
# the same commit SHA across distinct runs, or a run that passed only on a
# re-run attempt (attempt > 1). A pass on the same SHA means the code did not
# change between the red and the green, so the red was not the code.
#
# The report is read-only against GitHub and writes nothing to the home.
# A repository whose runs cannot be read is listed under "Errors" and the
# script exits 1 after printing the rest of the report.
#
# Usage:
#   fm-ci-rescan.sh [--limit N] [--out FILE] [scope-token...]
#
# Scope tokens and their configuration are owned by bin/fm-ci-lib.sh
# (`org:<owner>`, `<owner>/<name>`, FM_CI_SCOPE, config/ci-watch-scope).
#
# Environment:
#   FM_HOME       operational home whose config/ holds ci-watch-scope.
#   FM_CI_NOW     epoch seconds to use as "now" in the header (tests).
#
# Requires gh (authenticated) and jq.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ci-lib.sh
. "$SELF_DIR/fm-ci-lib.sh"

die() { printf 'fm-ci-rescan: %s\n' "$*" >&2; exit "${2:-1}"; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

limit=200
out=""
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --limit) [ "$#" -ge 2 ] || die "--limit needs a value" 2; limit=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || die "--out needs a path" 2; out=$2; shift 2 ;;
    --) shift; args+=("$@"); break ;;
    -*) die "unknown option: $1 (try --help)" 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$limit" in ''|*[!0-9]*) die "--limit must be a positive integer" 2 ;; esac

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

rc=0
scope=$(fm_ci_resolve_scope "${args[@]+"${args[@]}"}") || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ -n "$scope" ] || die "the scope resolved to no repositories"

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-rescan.XXXXXX")
trap 'rm -rf "$work"' EXIT

fields=databaseId,name,workflowName,conclusion,status,event,headBranch,headSha,createdAt,updatedAt,attempt,url
errors=0
n=0
while IFS=$'\t' read -r repo branch; do
  n=$((n + 1))
  if runs=$(gh run list -R "$repo" --branch "$branch" --limit "$limit" --json "$fields" 2>"$work/err") &&
    printf '%s' "$runs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    jq -n --arg repo "$repo" --arg branch "$branch" --argjson runs "$runs" \
      '{repo: $repo, branch: $branch, runs: $runs}' >"$work/$n.json"
  else
    errors=$((errors + 1))
    jq -n --arg repo "$repo" --arg branch "$branch" --arg err "$(head -c 300 "$work/err" | tr '\n' ' ')" \
      '{repo: $repo, branch: $branch, error: $err}' >"$work/$n.json"
  fi
done <<<"$scope"

now=${FM_CI_NOW:-$(date +%s)}

# One jq program owns every metric and the whole report layout.
report=$(jq -rs --argjson now "$now" --argjson limit "$limit" '
  def dur: if . == null then "-" else
    (. | floor) as $s |
    if $s < 60 then "\($s)s"
    elif $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
    else "\($s / 86400 | floor)d \($s % 86400 / 3600 | floor)h" end end;
  def median: sort | length as $n |
    if $n == 0 then null
    elif $n % 2 == 1 then .[($n - 1) / 2]
    else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
  def failed: .conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure";
  def passed: .conclusion == "success";
  def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  def ids: (.[0:5] | map(tostring) | join(", ")) + (if length > 5 then " and \(length - 5) more" else "" end);
  def pct: (. * 1000 | round) / 10 | tostring + "%";

  def stats($repo; $branch):
    [.[] | select(.status == "completed")] | group_by(.workflowName) | map(
      sort_by(.createdAt) as $r |
      [$r[] | select(failed or passed)] as $d |
      ($d | reduce .[] as $x ({red: null, ttg: []};
          if ($x | failed) then (if .red == null then .red = ($x.updatedAt | epoch) else . end)
          elif .red != null then .ttg += [($x.updatedAt | epoch) - .red] | .red = null
          else . end)) as $streak |
      ([$d[] | select(.event != "dynamic")] | group_by(.headSha) | map(select((any(.[]; failed)) and (any(.[]; passed))))
          | map({sha: .[0].headSha, events: ([.[].event] | unique),
                 failed: [.[] | select(failed) | .databaseId], passed: [.[] | select(passed) | .databaseId]})) as $same_sha |
      ([$r[] | select(passed and ((.attempt // 1) > 1))] | map({sha: .headSha, id: .databaseId, attempt: .attempt, events: [.event]})) as $reruns |
      {
        repo: $repo, branch: $branch, workflow: $r[0].workflowName,
        runs: ($r | length),
        failures: ([$d[] | select(failed)] | length),
        decisive: ($d | length),
        rate: (if ($d | length) == 0 then 0 else ([$d[] | select(failed)] | length) / ($d | length) end),
        ttg_median: ($streak.ttg | median),
        streaks_fixed: ($streak.ttg | length),
        red_now: ($streak.red != null),
        red_since: $streak.red,
        same_sha: $same_sha,
        reruns: $reruns
      });

  (map(select(.error == null) | . as $e | .runs | stats($e.repo; $e.branch)) | add // []) as $all |
  map(select(.error != null)) as $errs |

  "# CI rescan - \($now | todate | .[0:10])",
  "",
  "Generated by `fm-ci-rescan.sh` at \($now | todate).",
  "Scope: \(length) repositories; up to \($limit) most recent runs per repository on its default branch.",
  "Failure rate counts failure, timed_out and startup_failure against success; cancelled and skipped runs are excluded.",
  "Time-to-green is the median time from the end of the first failing run of a red streak to the end of the next successful run of the same workflow.",
  "",
  "## Worst workflows by failure rate",
  "",
  "Workflows with at least 3 decisive runs and at least one failure, worst first.",
  "",
  "| Repository | Workflow | Runs | Failures | Failure rate | Median time-to-green | Red now |",
  "| --- | --- | ---: | ---: | ---: | ---: | --- |",
  ($all | map(select(.decisive >= 3 and .failures > 0)) | sort_by(-.rate, -.failures) | .[0:20][] |
    "| \(.repo) | \(.workflow) | \(.runs) | \(.failures) | \(.rate | pct) | \(.ttg_median | dur) | \(if .red_now then "yes, since \(.red_since | todate)" else "no" end) |"),
  "",
  "## Red now",
  "",
  (($all | map(select(.red_now)) | sort_by(.red_since)) as $red |
    if ($red | length) == 0 then "Nothing is red on a default branch."
    else ($red[] | "- \(.repo) `\(.workflow)` on `\(.branch)`: red since \(.red_since | todate) (\(($now - .red_since) | dur))") end),
  "",
  "## Flaky candidates",
  "",
  "A workflow that both failed and passed on the same commit, or passed only on a re-run attempt.",
  "Runs with event `dynamic` (Dependabot Updates, default-setup CodeQL) are left out: one such workflow name covers many unrelated jobs on one commit.",
  "On a `schedule` event the code is the same by construction, so a flip there points at something outside the repository (an advisory database, a remote service, a token).",
  "",
  (($all | map(select((.same_sha | length) > 0 or (.reruns | length) > 0))) as $fl |
    if ($fl | length) == 0 then "None found in the window."
    else
      "| Repository | Workflow | Commit | Events | Failed runs | Passed runs |",
      "| --- | --- | --- | --- | --- | --- |",
      ($fl[] | . as $w |
        (.same_sha[] | "| \($w.repo) | \($w.workflow) | `\(.sha[0:7])` | \(.events | join(", ")) | \(.failed | ids) | \(.passed | ids) |"),
        (.reruns[] | "| \($w.repo) | \($w.workflow) | `\(.sha[0:7])` | \(.events | join(", ")) | earlier attempt of \(.id) | \(.id) (attempt \(.attempt)) |"))
    end),
  "",
  "## Per repository",
  "",
  ($all | group_by(.repo)[] |
    "### \(.[0].repo) (`\(.[0].branch)`)",
    "",
    "| Workflow | Runs | Failures | Failure rate | Median time-to-green | Red streaks fixed | Red now |",
    "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
    (sort_by(-.rate, .workflow)[] |
      "| \(.workflow) | \(.runs) | \(.failures) | \(.rate | pct) | \(.ttg_median | dur) | \(.streaks_fixed) | \(if .red_now then "yes" else "no" end) |"),
    ""),
  (map(select(.error == null and (.runs | length) == 0) | .repo) as $quiet |
    if ($quiet | length) == 0 then empty else
      "Repositories with no runs on their default branch: \($quiet | join(", ")).",
      "" end),
  (if ($errs | length) == 0 then empty else
    "## Errors",
    "",
    ($errs[] | "- \(.repo): could not read runs: \(.error)"),
    "" end)
' "$work"/*.json)

if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$report" >"$out"
  printf 'fm-ci-rescan: wrote %s\n' "$out" >&2
else
  printf '%s\n' "$report"
fi

[ "$errors" -eq 0 ] || exit 1
