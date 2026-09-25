#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-watch.sh, the scheduled failed-CI-run poller.
#
# gh is a PATH shim that serves fixture JSON per repository (and applies --jq
# the way gh does), so no case contacts GitHub. Covered:
#
#   * first run: every failure listed is recorded as seen, only those from the
#     last 24 hours are delivered (no flood);
#   * dedupe: a second poll over the same runs delivers nothing, a new failure
#     is delivered once, and several new failures of one workflow collapse into
#     one entry while distinct workflows get one entry each;
#   * delivery: a note through fm-inbox and an entry in the owning
#     repository's agent-context/INBOX.md, placed after an H1 preamble;
#   * gh auth/network failure: exit non-zero, seen state byte-identical, no
#     delivery, other repositories still polled;
#   * no scope configured: refusal naming the config file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-ci-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-watch)
FAKEBIN="$TMP_ROOT/fakebin"
NOW=1790000000   # 2026-09-21T14:13:20Z

iso() { jq -rn --argjson t "$1" '$t | todate'; }

mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
# Fixture gh: FAKE_GH_DIR/<owner>__<name>.runs.json answers `run list -R`,
# FAKE_GH_DIR/<owner>__<name>.fail makes that repository's calls fail like a
# lost token, <owner>__<name>.runfail fails only `run list` like a network
# drop, and `repo view` reports branch main for any repository.
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
if [ -e "$FAKE_GH_DIR/$key.fail" ]; then
  echo 'HTTP 401: Bad credentials (https://api.github.com/graphql)' >&2
  exit 1
fi
if [ "$sub" = "run list" ] && [ -e "$FAKE_GH_DIR/$key.runfail" ]; then
  echo 'error connecting to api.github.com' >&2
  exit 1
fi
case "$sub" in
  "repo view")
    body=$(jq -n --arg r "$repo" '{nameWithOwner: $r, isArchived: false, isEmpty: false, defaultBranchRef: {name: "main"}}') ;;
  "run list")
    body=$(cat "$FAKE_GH_DIR/$key.runs.json" 2>/dev/null || echo '[]') ;;
  *) echo "fake gh: unsupported: $sub" >&2; exit 64 ;;
esac
if [ -n "$jqf" ]; then printf '%s' "$body" | jq -r "$jqf"; else printf '%s\n' "$body"; fi
SH
chmod +x "$FAKEBIN/gh"

# run_json <id> <workflow> <age-seconds>: one failed run, created <age> ago.
run_json() {
  jq -n --argjson id "$1" --arg wf "$2" --arg at "$(iso $((NOW - $3)))" \
    '{databaseId: $id, workflowName: $wf, headBranch: "main", headSha: "abcdef1234567890",
      event: "push", createdAt: $at, updatedAt: $at, attempt: 1,
      url: "https://github.com/o/r/actions/runs/\($id)"}'
}

# set_runs <world> <owner__name> <run-json>...: the failed-run listing.
set_runs() {
  local world=$1 key=$2
  shift 2
  printf '%s\n' "$@" | jq -s . >"$world/gh/$key.runs.json"
}

# make_world <name>: a home, a gh fixture dir and an inbox root with a
# checkout for o/r whose INBOX.md has an H1 preamble and one older entry.
make_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/gh" "$w/ws/r/agent-context"
  printf '%s\n' '# INBOX - r' '' 'Operator queue.' '' '## older entry' 'body' >"$w/ws/r/agent-context/INBOX.md"
  printf '%s\n' "$w"
}

# watch <world> [args...]: run the watcher; stdout+stderr to <world>/out.
watch() {
  local w=$1 rc=0
  shift
  env FM_HOME="$w/home" FM_CI_INBOX_ROOT="$w/ws" FM_CI_NOW="$NOW" FAKE_GH_DIR="$w/gh" \
    PATH="$FAKEBIN:$PATH" "$WATCH" "$@" >"$w/out" 2>&1 || rc=$?
  return "$rc"
}

notes() { find "$1/home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '; }
entries() { grep -c '^## .*CI failed' "$1/ws/r/agent-context/INBOX.md"; }

test_first_run_records_history_and_delivers_only_the_last_day() {
  local w seen
  w=$(make_world first)
  set_runs "$w" o__r "$(run_json 101 build $((3 * 86400)))" "$(run_json 102 build $((2 * 86400)))" \
    "$(run_json 103 build 3600)"
  watch "$w" o/r || fail "first run must succeed: $(cat "$w/out")"
  assert_equals 1 "$(entries "$w")" "first run writes one INBOX entry, not the history"
  assert_equals 1 "$(notes "$w")" "first run queues one fm-inbox note"
  assert_grep 'fm-ci-watch run=103 ' "$w/ws/r/agent-context/INBOX.md" "the recent failure is the one delivered"
  assert_no_grep 'run=101' "$w/ws/r/agent-context/INBOX.md" "a three-day-old failure is not delivered"
  seen=$(sort "$w/home/state/ci-watch/o__r.seen" | tr '\n' ' ')
  assert_equals "101 102 103 " "$seen" "every listed failure is recorded as seen"
  pass "fm-ci-watch: first run records history and delivers only the last 24h"
}

test_second_poll_is_a_no_op_and_a_new_failure_is_delivered_once() {
  local w before
  w=$(make_world dedupe)
  set_runs "$w" o__r "$(run_json 201 build 600)"
  watch "$w" o/r || fail "first poll must succeed: $(cat "$w/out")"
  before=$(cat "$w/home/state/ci-watch/o__r.seen")
  watch "$w" o/r || fail "second poll must succeed: $(cat "$w/out")"
  assert_equals 1 "$(entries "$w")" "an unchanged listing writes nothing new"
  assert_equals 1 "$(notes "$w")" "an unchanged listing queues no note"
  assert_equals "$before" "$(cat "$w/home/state/ci-watch/o__r.seen")" "an unchanged listing leaves state as it was"

  set_runs "$w" o__r "$(run_json 201 build 600)" "$(run_json 202 build 300)"
  watch "$w" o/r || fail "third poll must succeed: $(cat "$w/out")"
  watch "$w" o/r || fail "fourth poll must succeed: $(cat "$w/out")"
  assert_equals 2 "$(entries "$w")" "a new failure is delivered exactly once"
  assert_equals 2 "$(notes "$w")" "a new failure queues exactly one note"
  assert_equals 1 "$(grep -c 'run=202 ' "$w/ws/r/agent-context/INBOX.md")" "the new run appears once"
  pass "fm-ci-watch: a repeat poll is a no-op and a new failure is delivered once"
}

test_new_failures_group_per_workflow() {
  local w
  w=$(make_world group)
  mkdir -p "$w/home/state/ci-watch"
  : >"$w/home/state/ci-watch/o__r.seen"
  set_runs "$w" o__r "$(run_json 301 build 900)" "$(run_json 302 build 600)" "$(run_json 303 lint 300)"
  watch "$w" o/r || fail "poll must succeed: $(cat "$w/out")"
  assert_equals 2 "$(entries "$w")" "two workflows, two entries"
  assert_equals 2 "$(notes "$w")" "two workflows, two notes"
  assert_grep 'Earlier new failures of this workflow' "$w/ws/r/agent-context/INBOX.md" "the grouped entry lists the earlier run"
  assert_grep 'https://github.com/o/r/actions/runs/301' "$w/ws/r/agent-context/INBOX.md" "the earlier run's URL is kept"
  pass "fm-ci-watch: several new failures of one workflow make one entry"
}

test_entry_lands_after_the_preamble_newest_first() {
  local w first_h2
  w=$(make_world order)
  set_runs "$w" o__r "$(run_json 401 build 60)"
  watch "$w" o/r || fail "poll must succeed: $(cat "$w/out")"
  assert_equals "# INBOX - r" "$(head -n 1 "$w/ws/r/agent-context/INBOX.md")" "the H1 preamble stays on top"
  first_h2=$(grep -m 1 '^## ' "$w/ws/r/agent-context/INBOX.md")
  assert_contains "$first_h2" "CI failed: build on \`main\` (o/r)" "the new entry is the first H2"
  assert_grep '## older entry' "$w/ws/r/agent-context/INBOX.md" "existing entries are kept"
  pass "fm-ci-watch: the entry is inserted newest-first after the preamble"
}

test_gh_failure_exits_nonzero_and_keeps_state() {
  local w before inbox_before rc=0
  w=$(make_world authfail)
  mkdir -p "$w/ws/q/agent-context"
  set_runs "$w" o__r "$(run_json 501 build 600)"
  watch "$w" o/r || fail "seed poll must succeed: $(cat "$w/out")"
  before=$(cat "$w/home/state/ci-watch/o__r.seen")
  inbox_before=$(cat "$w/ws/r/agent-context/INBOX.md")

  # o/r loses its token while it has a new failure; o/q still answers.
  set_runs "$w" o__r "$(run_json 501 build 600)" "$(run_json 502 build 60)"
  set_runs "$w" o__q "$(run_json 601 build 60)"
  : >"$w/gh/o__r.fail"
  watch "$w" o/r o/q || rc=$?
  # Scope resolution calls `repo view` for o/r too, so the whole run refuses
  # before touching any state.
  expect_code 1 "$rc" "a gh failure exits non-zero"
  assert_contains "$(cat "$w/out")" "could not read repository o/r" "the failing repository is named"
  assert_equals "$before" "$(cat "$w/home/state/ci-watch/o__r.seen")" "seen state is untouched"
  assert_equals "$inbox_before" "$(cat "$w/ws/r/agent-context/INBOX.md")" "nothing is delivered"
  assert_absent "$w/home/state/ci-watch/o__q.seen" "no other repository's state is written when the scope is incomplete"
  assert_absent "$w/home/state/ci-watch/.lock" "the lock is released"
  pass "fm-ci-watch: an unresolvable scope exits non-zero and writes nothing"
}

test_run_list_failure_keeps_that_repo_state_and_polls_the_others() {
  local w before inbox_before rc=0
  w=$(make_world listfail)
  mkdir -p "$w/ws/q/agent-context"
  set_runs "$w" o__r "$(run_json 701 build 600)"
  watch "$w" o/r || fail "seed poll must succeed: $(cat "$w/out")"
  before=$(cat "$w/home/state/ci-watch/o__r.seen")
  inbox_before=$(cat "$w/ws/r/agent-context/INBOX.md")

  # o/r has a new failure but its run list drops; o/q is healthy.
  set_runs "$w" o__r "$(run_json 701 build 600)" "$(run_json 702 build 60)"
  set_runs "$w" o__q "$(run_json 801 build 60)"
  : >"$w/gh/o__r.runfail"
  watch "$w" o/r o/q || rc=$?
  expect_code 1 "$rc" "a run-list failure exits non-zero"
  assert_contains "$(cat "$w/out")" "o/r: could not list failed runs" "the failing repository is named"
  assert_equals "$before" "$(cat "$w/home/state/ci-watch/o__r.seen")" "the failing repository's seen state is untouched"
  assert_equals "$inbox_before" "$(cat "$w/ws/r/agent-context/INBOX.md")" "nothing is delivered for it"
  assert_grep 'fm-ci-watch run=801 ' "$w/ws/q/agent-context/INBOX.md" "the healthy repository is still polled and delivered"

  # Once the network is back, the missed failure is delivered.
  rm -f "$w/gh/o__r.runfail"
  watch "$w" o/r o/q || fail "recovery poll must succeed: $(cat "$w/out")"
  assert_grep 'fm-ci-watch run=702 ' "$w/ws/r/agent-context/INBOX.md" "the failure missed during the outage is delivered after it"

  # Unparseable output is an error too, and a failed first poll writes no state.
  printf 'not json\n' >"$w/gh/o__z.runs.json"
  rc=0
  watch "$w" o/z || rc=$?
  expect_code 1 "$rc" "unparseable run-list output exits non-zero"
  assert_absent "$w/home/state/ci-watch/o__z.seen" "a failed first poll creates no state, so the next one is still a first run"
  pass "fm-ci-watch: a run-list failure keeps that repository's state and polls the rest"
}

test_inbox_lookup_lowercase_map_and_workspace_fallback() {
  local w
  w=$(make_world lookup)
  mkdir -p "$w/ws/mixed/agent-context" "$w/ws/agent-context" "$w/other" "$w/home/config"
  printf '# INBOX - workspace\n' >"$w/ws/agent-context/INBOX.md"
  printf '%s\n' "o/Elsewhere $w/other/INBOX.md" >"$w/home/config/ci-watch-inbox-map"
  mkdir -p "$w/home/state/ci-watch"
  for key in o__Mixed o__Elsewhere o__none; do
    : >"$w/home/state/ci-watch/$key.seen"
  done
  set_runs "$w" o__Mixed "$(run_json 1001 build 60)"
  set_runs "$w" o__Elsewhere "$(run_json 1002 build 60)"
  set_runs "$w" o__none "$(run_json 1003 build 60)"
  watch "$w" o/Mixed o/Elsewhere o/none || fail "poll must succeed: $(cat "$w/out")"
  assert_grep 'fm-ci-watch run=1001 ' "$w/ws/mixed/agent-context/INBOX.md" "a checkout named in lower case is found"
  assert_grep 'fm-ci-watch run=1002 ' "$w/other/INBOX.md" "an inbox-map line overrides the lookup"
  assert_grep 'fm-ci-watch run=1003 ' "$w/ws/agent-context/INBOX.md" "a repository without a checkout goes to the workspace inbox"
  pass "fm-ci-watch: inbox lookup by name, lowercase name, map, and workspace fallback"
}

test_dry_run_writes_nothing() {
  local w
  w=$(make_world dry)
  set_runs "$w" o__r "$(run_json 901 build 60)"
  watch "$w" --dry-run o/r || fail "dry run must succeed: $(cat "$w/out")"
  assert_contains "$(cat "$w/out")" "would deliver CI failed: o/r build on main" "dry run says what it would deliver"
  assert_absent "$w/home/state/ci-watch" "dry run writes no state"
  assert_equals 0 "$(entries "$w")" "dry run writes no INBOX entry"
  pass "fm-ci-watch: --dry-run writes nothing"
}

test_no_scope_is_refused() {
  local w rc=0
  w=$(make_world noscope)
  env -u FM_CI_SCOPE FM_HOME="$w/home" FAKE_GH_DIR="$w/gh" PATH="$FAKEBIN:$PATH" \
    "$WATCH" >"$w/out" 2>&1 || rc=$?
  expect_code 2 "$rc" "no scope exits 2"
  assert_contains "$(cat "$w/out")" "$w/home/config/ci-watch-scope" "the refusal names the config file to write"
  pass "fm-ci-watch: no scope is refused with the file to write"
}

test_first_run_records_history_and_delivers_only_the_last_day
test_second_poll_is_a_no_op_and_a_new_failure_is_delivered_once
test_new_failures_group_per_workflow
test_entry_lands_after_the_preamble_newest_first
test_gh_failure_exits_nonzero_and_keeps_state
test_run_list_failure_keeps_that_repo_state_and_polls_the_others
test_inbox_lookup_lowercase_map_and_workspace_fallback
test_dry_run_writes_nothing
test_no_scope_is_refused
