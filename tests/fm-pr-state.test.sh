#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OLD_HEAD_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
OLD_HEAD_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test. The pull-request object speaks GitHub's own vocabulary: an
# uppercase state with MERGED as its own value, and a null mergeable while
# GitHub is still computing one.
# It evaluates with the local jq, while gh itself embeds gojq; the live guard in
# tests/fm-pr-state-live-e2e.test.sh runs the real engine.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
serve() {
  case "$*" in
    "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision,statusCheckRollup --jq "*)
      jq -n --arg head "$head" --arg state "${FM_TEST_STATE-OPEN}" \
        --arg merged "${FM_TEST_MERGED_AT-}" --arg draft "${FM_TEST_DRAFT-false}" \
        --arg mergeable "${FM_TEST_VIEW_MERGEABLE-MERGEABLE}" \
        --arg decision "${FM_TEST_VIEW_REVIEW_DECISION-APPROVED}" \
        --argjson checks "${FM_TEST_CHECK_ROLLUP:-[1,2]}" \
        '{state: $state, mergedAt: (if $merged == "" then null else $merged end),
          isDraft: ($draft == "true"), headRefOid: $head,
          author: {login: "prauthor", is_bot: false},
          mergeable: (if $mergeable == "null" then null else $mergeable end),
          reviewDecision: $decision, statusCheckRollup: (if $checks == [1,2] then [{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"optional","status":"COMPLETED","conclusion":"SKIPPED"}] else $checks end)}'
      ;;
    "api graphql "*)
      if [ "${FM_TEST_THREADS_ERROR:-0}" = 1 ]; then printf '%s\n' 'HTTP 502' >&2; exit 1; fi
      jq -cn --argjson threads "${FM_TEST_THREADS:-[]}" \
        '[{data:{repository:{pullRequest:{reviewThreads:{nodes:(if ($threads|length)>0 and ($threads[0]|type)=="array" then $threads[0] else $threads end),pageInfo:{hasNextPage:false,endCursor:null}}}}}}]'
      ;;
    "api /repos/o/r/pulls/7/reviews?per_page=100 --paginate --jq "*)
      printf '%s\n' "${FM_TEST_REVIEWS:-[]}"
      ;;
    *)
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 91
      ;;
  esac
}
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
case "$1" in
  api) if [ "$2" = graphql ]; then serve "$@"; else serve "$@" | jq -r "$prog"; fi ;;
  *) serve "$@" | jq -r "$prog" ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_state() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" https://github.com/o/r/pull/7
}

# reviews "<login> <state> <commit> <submitted_at>"... prints the JSON array
# GitHub's reviews endpoint returns for those submissions.
reviews() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" "))
    | map({user: {login: .[0], type: .[1]}, state: .[2], commit_id: .[3], submitted_at: .[4]})'
}

test_clean_pr_reports_complete_inventory() {
  local out
  out=$(run_state) || fail "clean fixture was refused"
  assert_contains "$out" 'CHECK SUMMARY: total=2 pass=2 fail=0 pending=0' "all pass and skipped entries are counted"
  assert_contains "$out" 'CHECK: lint status=COMPLETED/SUCCESS' "the passing check is enumerated"
  assert_contains "$out" 'CHECK: optional status=COMPLETED/SKIPPED' "the skipped check is enumerated"
  assert_contains "$out" 'REVIEW THREADS: unresolved=0' "review-thread read is explicit"
  pass "the independent PR-state reader enumerates every check and unresolved thread count"
}
test_terminal_state_is_the_whole_report() {
  local out
  out=$(FM_TEST_STATE=CLOSED run_state) || fail "closed fixture was refused"
  [ "$out" = 'STATE: closed' ] \
    || fail "a closed pull request reports terminal state only, got: $out"
  out=$(FM_TEST_STATE=MERGED FM_TEST_MERGED_AT=2019-10-04T16:01:04Z \
    FM_TEST_VIEW_MERGEABLE=null FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "merged fixture was refused"
  [ "$out" = 'STATE: merged at 2019-10-04T16:01:04Z' ] \
    || fail "a merged pull request reports terminal state only, got: $out"
  pass "terminal pull request state short-circuits the open check inventory"
}

test_draft_is_a_blocker() {
  local out
  out=$(FM_TEST_DRAFT=true run_state) || fail "draft fixture was refused"
  assert_contains "$out" 'DRAFT: pull request is not ready for review' \
    "a draft pull request leaves the author something to do"
  pass "draft state blocks readiness"
}

test_all_checks_and_unresolved_threads_are_reported() {
  local out
  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"deploy","status":"IN_PROGRESS","conclusion":null},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","context":"legacy","state":"ERROR"}]' \
    FM_TEST_THREADS='[[{"id":"PRRT_kw_unresolved","url":"https://github.com/o/r/pull/7#discussion_r7","isResolved":false},{"id":"PRRT_kw_resolved","url":"https://github.com/o/r/pull/7#discussion_r8","isResolved":true}]]' run_state) \
    || fail "mixed check and thread fixture was refused"
  assert_contains "$out" 'CHECK SUMMARY: total=4 pass=1 fail=2 pending=1' "summary includes passing, failed, and pending checks"
  assert_contains "$out" 'CHECK: legacy status=ERROR' "non-required status context is enumerated"
  assert_contains "$out" 'REVIEW THREADS: unresolved=1' "only unresolved threads are counted"
  assert_contains "$out" 'UNRESOLVED THREAD: id=PRRT_kw_unresolved' "unresolved thread identity is named"
  status=0
  FM_TEST_THREADS_ERROR=1 run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "an unreadable review-thread lookup must refuse a verified inventory"
  pass "all check classes, unresolved threads, and thread-read failures are independently reported"
}

test_stale_blocking_reviews_explain_a_blocking_decision() {
  local out history expected
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "commenter User COMMENTED $OLD_HEAD_2 2026-09-01T23:10:00Z" \
    "alice User APPROVED $OLD_HEAD_2 2026-09-01T23:11:00Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "voided-review fixture was refused"
  expected=$(printf 'REVIEW DECISION: CHANGES_REQUESTED\nSTALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at %s' "$OLD_HEAD_2")
  assert_contains "$out" "STALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $OLD_HEAD_2" \
    "stale blocking review identifies the commit it remains attached to"
  assert_not_contains "$out" "$OLD_HEAD_1" "superseded stale review is omitted"
  assert_not_contains "$out" 'commenter' "stale comments are not blockers"
  assert_not_contains "$out" 'alice' "stale approvals are not blockers"
  pass "stale changes-requested verdicts explain a blocking review decision"
}

test_approved_pr_with_only_stale_changes_requested_is_silent() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=APPROVED FM_TEST_REVIEWS=$history run_state) \
    || fail "approved stale-review fixture was refused"
  assert_not_contains "$out" 'REVIEW:' "stale review history does not override approval"
  assert_not_contains "$out" 'STALE BLOCKING REVIEW:' "approved head does not report stale changes as blocking"
  pass "approved PR ignores stale changes-requested history"
}

test_current_changes_requested_review_is_a_blocker() {
  local out history
  history=$(reviews "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "current-review fixture was refused"
  assert_contains "$out" 'REVIEW: coderabbitai[bot] CHANGES_REQUESTED' \
    "current changes-requested verdict names its reviewer"
  pass "current changes-requested review blocks readiness"
}

test_changes_requested_decision_is_never_silent() {
  local out history
  history=$(reviews \
    "bob User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "bob User COMMENTED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "comment-after-changes fixture was refused"
  assert_contains "$out" 'REVIEW: bob CHANGES_REQUESTED' \
    "later comment does not erase reviewer's change request"

  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "decision-only fixture was refused"
  assert_contains "$out" 'REVIEW DECISION: CHANGES_REQUESTED' \
    "blocking review decision is emitted without review detail"
  pass "a CHANGES_REQUESTED decision is always reported"
}

test_authors_own_changes_requested_review_is_not_a_blocker() {
  local out history
  history=$(reviews "prauthor User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "self-review fixture was refused"
  assert_not_contains "$out" 'REVIEW: prauthor' \
    "the author's own verdict is not a reviewer blocking them"
  pass "the author's own review is never listed as a blocker"
}
test_pending_approval_is_not_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_REVIEW_DECISION=REVIEW_REQUIRED run_state) \
    || fail "review-required fixture was refused"
  assert_contains "$out" 'REVIEW THREADS: unresolved=0' \
    "review thread inventory is independently included"
  assert_not_contains "$out" 'REVIEW DECISION:' \
    "review-required is a pending approval rather than a blocker"
  pass "a pending approval is not reported as a blocker"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"required","status":"COMPLETED","conclusion":"FAILURE"}]' run_state) || fail "failure fixture refused"
  assert_contains "$out" "fail=1" "failed check counted"
  pass "failing checks appear in inventory"
}

test_check_inventory_is_not_empty_or_incomplete() {
  local out occurrences needle
  out=$(FM_TEST_CHECK_ROLLUP='[]' run_state) || fail "empty fixture refused"
  assert_contains "$out" "CHECK SUMMARY: total=0" "zero checks represented"
  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"one","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"two","status":"COMPLETED","conclusion":"SUCCESS"}]' run_state) \
    || fail "two-check fixture refused"
  assert_contains "$out" 'CHECK SUMMARY: total=2 pass=2 fail=0 pending=0' "both checks counted"
  assert_contains "$out" 'CHECK: one status=COMPLETED/SUCCESS' "first check enumerated"
  assert_contains "$out" 'CHECK: two status=COMPLETED/SUCCESS' "second check enumerated"
  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"same","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"same","status":"COMPLETED","conclusion":"SUCCESS"}]' run_state) \
    || fail "duplicate-name fixture refused"
  assert_contains "$out" 'CHECK SUMMARY: total=2 pass=2 fail=0 pending=0' "duplicate names remain separate checks"
  needle='CHECK: same status=COMPLETED/SUCCESS'
  occurrences=${out//"$needle"/}
  [ "$(( (${#out} - ${#occurrences}) / ${#needle} ))" -eq 2 ] || fail "duplicate check names must each be enumerated"
  pass "check summary and complete per-entry inventory are distinguished"
}

test_unreported_required_checks_are_unconfirmed() {
  local out status
  out=$(FM_TEST_CHECKS_ERROR="no required checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported required checks was refused"
  [ "$out" = 'CHECKS: no required check has reported; readiness unconfirmed' ] \
    || fail "a head where nothing required has reported must not pass silently as ready, got: $out"
  status=0
  FM_TEST_CHECKS_ERROR='HTTP 502: Bad Gateway' run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a real check lookup failure must still refuse"
  pass "required-check absence is unconfirmed while other lookup failures refuse"
}

test_no_reported_checks_is_unverified() {
  local out
  out=$(FM_TEST_CHECKS_ERROR="no checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported checks was refused"
  [ "$out" = 'CHECKS: none reported yet' ] \
    || fail "a head with no reported checks must read as unverified, not ready, got: $out"
  pass "a head with no reported checks is unverified rather than ready"
}

test_help_states_what_silence_means_and_what_is_out_of_scope() {
  local out
  out=$("$SCRIPT" --help) || fail "help was refused"
  assert_contains "$out" 'complete status-check rollup' "help describes the complete check inventory"
  assert_contains "$out" 'review threads' "help documents thread reporting"
  pass "help states what empty output means and what is out of scope"
}

test_unknown_mergeability_is_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"

  out=$(FM_TEST_VIEW_MERGEABLE=CONFLICTING run_state) \
    || fail "conflicting fixture was refused"
  assert_contains "$out" 'MERGEABILITY: conflicting' \
    "a conflicting merge state must be reported"
  pass "unknown and conflicting mergeability block readiness"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"required","status":"COMPLETED","conclusion":"FAILURE"}]' run_state) || fail "failure fixture refused"
  assert_contains "$out" "fail=1" "failed check counted"
  pass "failing checks appear in inventory"
}

test_check_inventory_is_not_empty_or_incomplete() {
  local out occurrences needle
  out=$(FM_TEST_CHECK_ROLLUP='[]' run_state) || fail "empty fixture refused"
  assert_contains "$out" "CHECK SUMMARY: total=0" "zero checks represented"

  # Each entry must appear once in the enumerated inventory; a summary count
  # alone is not enough to prove that all checks were returned.
  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"one","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"two","status":"COMPLETED","conclusion":"SUCCESS"}]' run_state) \
    || fail "two-check fixture refused"
  assert_contains "$out" 'CHECK SUMMARY: total=2 pass=2 fail=0 pending=0' "both checks counted"
  assert_contains "$out" 'CHECK: one status=COMPLETED/SUCCESS' "first check enumerated"
  assert_contains "$out" 'CHECK: two status=COMPLETED/SUCCESS' "second check enumerated"

  out=$(FM_TEST_CHECK_ROLLUP='[{"__typename":"CheckRun","name":"same","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"same","status":"COMPLETED","conclusion":"SUCCESS"}]' run_state) \
    || fail "duplicate-name fixture refused"
  assert_contains "$out" 'CHECK SUMMARY: total=2 pass=2 fail=0 pending=0' "duplicate names remain separate checks"
  needle='CHECK: same status=COMPLETED/SUCCESS'
  occurrences=${out//"$needle"/}
  [ "$(( (${#out} - ${#occurrences}) / ${#needle} ))" -eq 2 ] \
    || fail "duplicate check names must each be enumerated"
  pass "check summary and complete per-entry inventory are distinguished"
}


test_refusals_exit_nonzero() {
  local status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lookup refusal exited zero"

  local out
  status=0
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" 7 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "a bare number resolves against the ambient repository and is not an address"
  assert_contains "$out" 'expected a GitHub pull-request URL' \
    "a bare number must be refused as an address, not attempted as a lookup"
  pass "argument and lookup refusals exit nonzero"
}

test_clean_pr_reports_complete_inventory
test_terminal_state_is_the_whole_report
test_draft_is_a_blocker
test_stale_blocking_reviews_explain_a_blocking_decision
test_approved_pr_with_only_stale_changes_requested_is_silent
test_current_changes_requested_review_is_a_blocker
test_changes_requested_decision_is_never_silent
test_authors_own_changes_requested_review_is_not_a_blocker
test_pending_approval_is_not_a_blocker
test_required_failure_is_a_blocker
test_help_states_what_silence_means_and_what_is_out_of_scope
test_unknown_mergeability_is_a_blocker
test_refusals_exit_nonzero
