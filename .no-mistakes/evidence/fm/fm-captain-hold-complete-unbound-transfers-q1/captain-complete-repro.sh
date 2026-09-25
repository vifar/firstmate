#!/usr/bin/env bash
# Live product driver for the bin/fm-captain-hold.sh complete crash.
#
# This does NOT call test functions. It stands up an isolated FM_HOME the same
# way an end user's home is shaped (backlog + state + meta), registers a real
# captain-held task, and invokes the real CLI as a subprocess exactly as the
# captain-call completion gate does. It prints the observable CLI transcript,
# the persisted meta, and the status stream.
#
# CAPTAIN_BIN selects the script under test so the same driver can show the
# pre-fix crash and the post-fix behavior.
set -u

REPO=${REPO:-/Users/king/.no-mistakes/worktrees/af95b24e5115/01M3CSTMAMNT011QAV1TBM9N3C}
CAPTAIN_BIN=${CAPTAIN_BIN:-$REPO/bin/fm-captain-hold.sh}
TASKS_AXI_BIN=$(command -v tasks-axi || true)
case "$TASKS_AXI_BIN" in
  '') echo "skip: tasks-axi not found" >&2; exit 77 ;;
esac
case "$(command -v jq || true)" in
  '') echo "skip: jq not found" >&2; exit 77 ;;
esac

# shellcheck source=tests/lib.sh
. "$REPO/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-complete-repro)

make_home() { # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$REPO/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s' "$home"
}

run_captain() { # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$CAPTAIN_BIN" "$@"
}

write_origin_meta() { # <home> <id>
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "spawn_gen=fixture-$id"
}

home=$(make_home resolved-inventory)
id=sample-settled-review
mkdir -p "$home/data/$id"
tasks_in_home() { (cd "$home" && tasks-axi "$@"); }
tasks_in_home add "$id" "Investigate sample settling" --kind scout --repo sample --start >/dev/null \
  || { echo "FAILED to create origin task"; exit 1; }
write_origin_meta "$home" "$id"
cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
resolved [key=route]: the captain chose route north
done: report complete
EOF
printf '# Sample settled review\n\nEvery captain choice is recorded.\n' > "$home/data/$id/report.md"
run_captain "$home" hold sample-settled-call \
  --title "Track the settled choice" --reason "captain settled choice pending" \
  --repo sample --origin "$id" >/dev/null 2>&1 \
  || { echo "FAILED to register captain-held task"; exit 1; }

echo "=== bin/fm-captain-hold.sh complete '$id' sample-settled-call ==="
out=$(run_captain "$home" complete "$id" sample-settled-call 2>"$home/err.txt")
rc=$?
err=$(cat "$home/err.txt")
printf 'exit=%s\n' "$rc"
printf 'stdout=[%s]\n' "$out"
printf 'stderr=[%s]\n' "$err"
echo "=== persisted $id.meta ==="
grep -E 'decisions_reviewed|decision_keys' "$home/state/$id.meta" || true
echo "=== status stream after complete ==="
cat "$home/state/$id.status"
echo "=== verify ==="
run_captain "$home" verify "$id" 2>&1
printf 'verify_exit=%s\n' "$?"
