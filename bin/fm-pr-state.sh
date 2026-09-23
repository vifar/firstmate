#!/usr/bin/env bash
# Report a complete current GitHub pull-request check inventory and blockers.
#
# This is a one-shot, read-only command. It reads the current pull request,
# complete status-check rollup, submitted reviews, review decision, and review
# threads from GitHub at invocation time. It never posts, requests, approves,
# or merges.
# Every rollup entry is enumerated; the summary counts pass, fail, pending, and
# skipped entries separately. An absent required context cannot be enumerated.
# Review-thread pagination is complete before output; unresolved threads are
# listed by node id and URL. Lookup or malformed-data errors exit nonzero.
# A closed or merged pull request reports that terminal state and nothing else.
#
# Usage: fm-pr-state.sh <pr-url>
#   Prints the check inventory, unresolved review threads, and blockers.
#   Lookup or usage refusal exits nonzero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"

URL=$1
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision,statusCheckRollup --jq '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")",
  "checks=\(.statusCheckRollup | if type == "array" then tojson else error("missing check rollup") end)"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
CHECKS=
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
    checks=*) CHECKS=${row#checks=} ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] && [ -n "$CHECKS" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

if [ -n "$MERGED_AT" ]; then
  printf 'STATE: merged at %s\n' "$MERGED_AT"
  exit 0
elif [ "$STATE" != open ]; then
  printf 'STATE: %s\n' "$STATE"
  exit 0
fi
[ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

printf '%s\n' "$CHECKS" | jq -e 'type == "array" and all(.[]; type == "object" and has("__typename"))' >/dev/null \
  || die "GitHub returned malformed check rollup for $URL"
printf '%s\n' "$CHECKS" | jq -r '
  def pass: if .__typename == "CheckRun" then .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED") else .state == "SUCCESS" end;
  def pending: if .__typename == "CheckRun" then .status != "COMPLETED" else .state == "PENDING" end;
  def check_label: if .__typename == "CheckRun" then (.name // "(unnamed check run)") else (.context // "(unnamed status context)") end;
  . as $all | [$all[] | select(pass)] as $passed
  | [$all[] | select(pending)] as $waiting
  | [$all[] | select((pass or pending) | not)] as $failed
  | "CHECK SUMMARY: total=\($all|length) pass=\($passed|length) fail=\($failed|length) pending=\($waiting|length)"
  , ($all[] | "CHECK: \(check_label) status=\(if .__typename == "CheckRun" then .status + "/" + (.conclusion // "") else .state end)")'

# shellcheck disable=SC2016
THREADS=$(gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{id isResolved url} pageInfo{hasNextPage endCursor}}}}}' \
  -f owner="${PATH_PART%%/*}" -f name="${PATH_PART#*/}" -F number="$NUMBER" --paginate --slurp) \
  || die "could not read review threads for $URL"
printf '%s\n' "$THREADS" | jq -e 'type == "array" and all(.[]; .data.repository.pullRequest.reviewThreads.nodes | type == "array")' >/dev/null \
  || die "GitHub returned malformed review threads for $URL"
printf '%s\n' "$THREADS" | jq -r '
  [ .[] | .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id:(.id // ""), url:(.url // "")} ] as $open
  | "REVIEW THREADS: unresolved=\($open|length)"
  , ($open[] | "UNRESOLVED THREAD: id=\(.id) url=\(.url)")'

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
    .[]
    | select(.user.login != null and .commit_id != null and .submitted_at != null)
    | [.user.login, .state, .commit_id, .submitted_at]
    | @tsv') || die "could not read reviews for $URL"
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 4 && $1 != author && $2 != "COMMENTED" && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1; latest[$1] = $4; state[$1] = $2; commit[$1] = $3
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head) printf "REVIEW: %s CHANGES_REQUESTED\n", reviewer
        else printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s\n", reviewer, commit[reviewer]
      }
    }' | LC_ALL=C sort
fi
