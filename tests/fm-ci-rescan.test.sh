#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-rescan.sh, the one-shot CI health survey.
#
# gh is a PATH shim serving fixture runs, so no case contacts GitHub. Covered:
# failure rate over decisive runs only, median time-to-green over red streaks,
# "red now", flaky detection (fail and pass on one SHA, and a pass on a re-run
# attempt), and an unreadable repository reported under Errors with exit 1
# while the rest of the report is still printed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESCAN="$ROOT/bin/fm-ci-rescan.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-rescan)
FAKEBIN="$TMP_ROOT/fakebin"
GHDIR="$TMP_ROOT/gh"
NOW=1790000000

mkdir -p "$FAKEBIN" "$GHDIR" "$TMP_ROOT/home"
cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
jqf="" repo="" sub="$1 ${2:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jqf=$2; shift 2 ;;
    -R) repo=$2; shift 2 ;;
    view) repo=${2:-}; shift ;;
    *) shift ;;
  esac
done
key=${repo%%/*}__${repo#*/}
case "$sub" in
  "repo view") body=$(jq -n --arg r "$repo" '{nameWithOwner: $r, isArchived: false, isEmpty: false, defaultBranchRef: {name: "main"}}') ;;
  "run list")
    [ -e "$FAKE_GH_DIR/$key.runs.json" ] || { echo 'HTTP 404: Not Found' >&2; exit 1; }
    body=$(cat "$FAKE_GH_DIR/$key.runs.json") ;;
  *) exit 64 ;;
esac
if [ -n "$jqf" ]; then printf '%s' "$body" | jq -r "$jqf"; else printf '%s\n' "$body"; fi
SH
chmod +x "$FAKEBIN/gh"

# run <id> <workflow> <conclusion> <sha> <start-offset> <end-offset> [attempt]
run() {
  jq -n --argjson id "$1" --arg wf "$2" --arg c "$3" --arg sha "$4" \
    --arg c_at "$(jq -rn --argjson t $((NOW - 100000 + $5)) '$t | todate')" \
    --arg u_at "$(jq -rn --argjson t $((NOW - 100000 + $6)) '$t | todate')" \
    --argjson attempt "${7:-1}" \
    '{databaseId: $id, name: $wf, workflowName: $wf, conclusion: $c, status: "completed",
      event: "push", headBranch: "main", headSha: $sha, createdAt: $c_at, updatedAt: $u_at,
      attempt: $attempt, url: "https://example.invalid/\($id)"}'
}

# build: pass, fail, fail, pass (green 1800s after the first red ended),
#        fail, cancelled, pass (green 600s after red): rate 3/6, ttg median 1200.
# lint: fail on sha L then pass on sha L (flaky), then fail (red now).
# deploy: pass on attempt 2 (re-run).
# deps: event dynamic, fail and pass on one SHA - separate jobs, not flaky.
{
  run 1 build success aaa 0 100
  run 2 build failure bbb 1000 1200
  run 3 build failure ccc 2000 2200
  run 4 build success ddd 2900 3000
  run 5 build failure eee 4000 4400
  run 6 build cancelled fff 4500 4600
  run 7 build success ggg 4900 5000
  run 8 lint failure LLL 100 150
  run 9 lint success LLL 200 250
  run 10 lint failure MMM 300 350
  run 11 deploy success DDD 100 200 2
  run 12 deps failure XXX 100 110
  run 13 deps success XXX 100 120
} | jq 'if .workflowName == "deps" then .event = "dynamic" else . end' | jq -s . >"$GHDIR/o__r.runs.json"

test_metrics_and_flaky_candidates() {
  local out
  out=$(env FM_HOME="$TMP_ROOT/home" FM_CI_NOW="$NOW" FAKE_GH_DIR="$GHDIR" PATH="$FAKEBIN:$PATH" \
    "$RESCAN" o/r 2>&1) || fail "rescan must succeed: $out"
  assert_contains "$out" "| o/r | build | 7 | 3 | 50% | 20m | no |" "build: 3 of 6 decisive runs failed, median time-to-green 1200s, cancelled excluded"
  assert_contains "$out" "| o/r | lint | 3 | 2 | 66.7% | 1m |" "lint: failure rate and time-to-green"
  assert_contains "$out" "- o/r \`lint\` on \`main\`: red since" "lint is red now"
  assert_contains "$out" "| o/r | lint | \`LLL\` | push | 8 | 9 |" "a fail and a pass on one SHA is a flaky candidate"
  assert_contains "$out" "| o/r | deploy | \`DDD\` | push | earlier attempt of 11 | 11 (attempt 2) |" "a pass on a re-run attempt is a flaky candidate"
  assert_not_contains "$out" "| o/r | deps | \`XXX\`" "dynamic-event runs sharing a SHA are not flaky candidates"
  pass "fm-ci-rescan: failure rate, time-to-green, red now and flaky candidates"
}

test_unreadable_repository_is_reported_and_exits_1() {
  local out rc=0
  out=$(env FM_HOME="$TMP_ROOT/home" FM_CI_NOW="$NOW" FAKE_GH_DIR="$GHDIR" PATH="$FAKEBIN:$PATH" \
    "$RESCAN" o/r o/missing 2>&1) || rc=$?
  expect_code 1 "$rc" "an unreadable repository exits 1"
  assert_contains "$out" "- o/missing: could not read runs: HTTP 404" "the unreadable repository is listed under Errors"
  assert_contains "$out" "### o/r (\`main\`)" "the readable repository is still reported"
  pass "fm-ci-rescan: an unreadable repository is reported and the run exits 1"
}

test_out_writes_the_report_file() {
  local file="$TMP_ROOT/reports/sub/report.md"
  env FM_HOME="$TMP_ROOT/home" FM_CI_NOW="$NOW" FAKE_GH_DIR="$GHDIR" PATH="$FAKEBIN:$PATH" \
    "$RESCAN" --out "$file" o/r >/dev/null 2>&1 || fail "rescan --out must succeed"
  assert_grep "# CI rescan - 2026-09-21" "$file" "--out writes the dated report, creating its directory"
  pass "fm-ci-rescan: --out writes the report file"
}

test_metrics_and_flaky_candidates
test_unreadable_repository_is_reported_and_exits_1
test_out_writes_the_report_file
