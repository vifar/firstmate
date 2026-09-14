#!/usr/bin/env bash
set -u
ROOT=/Users/king/.no-mistakes/worktrees/8457bd67d0a5/01M2FVHREAXJPDHT3ECVA02SF1
. "$ROOT/bin/fm-supervise-daemon.sh"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-stale-live.XXXXXX")
STATE="$CASE/state"
mkdir -p "$STATE"
SESSION="fm-stale-live-$$"
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; rm -rf "$CASE"; }
trap cleanup EXIT
export FM_STATE_OVERRIDE="$STATE" FM_ESCALATE_BATCH_SECS=999

tmux new-session -d -s "$SESSION" -n fm-active "while :; do printf live-worker-running; sleep 1; done"
printf 'window=%s:fm-active\nbackend=tmux\nworktree=%s\nkind=scout\nharness=claude\n' "$SESSION" "$ROOT" > "$STATE/active.meta"
"$ROOT/bin/fm-busy-event.sh" arm "$STATE" active >/dev/null
printf 'working: prior recorded progress\n' > "$STATE/active.status"
sleep 2
printf 'CURRENT ACTIVE: '
"$ROOT/bin/fm-crew-state.sh" active
handle_wake "stale: $SESSION:fm-active" "$STATE"
printf 'ACTIVE ESCALATION BUFFER: %s\n' "$(cat "$STATE/.subsuper-escalations" 2>/dev/null || printf '<empty>')"

printf 'window=%s:fm-missing\nbackend=tmux\nworktree=%s\nkind=scout\n' "$SESSION" "$ROOT" > "$STATE/missing.meta"
printf 'working: stale historical progress\n' > "$STATE/missing.status"
printf 'CURRENT MISSING: '
"$ROOT/bin/fm-crew-state.sh" missing
handle_wake "stale: $SESSION:fm-missing" "$STATE"
printf 'MISSING RECOVERY: %s\n' "$(tail -1 "$STATE/.subsuper-escalations")"

: > "$STATE/.subsuper-escalations"
printf 'window=%s:fm-paused\nbackend=tmux\nworktree=%s\nkind=scout\n' "$SESSION" "$ROOT" > "$STATE/paused.meta"
printf 'paused: old external wait\n' > "$STATE/paused.status"
printf 'CURRENT STALE-PAUSE: '
"$ROOT/bin/fm-crew-state.sh" paused
handle_wake "stale: $SESSION:fm-paused" "$STATE"
printf 'STALE-PAUSE RECOVERY: %s\n' "$(tail -1 "$STATE/.subsuper-escalations")"

: > "$STATE/.subsuper-escalations"
printf 'working: legacy historical progress\n' > "$STATE/legacy.status"
handle_wake "stale: $SESSION:fm-legacy" "$STATE"
printf 'UNRECORDED RECOVERY: %s\n' "$(tail -1 "$STATE/.subsuper-escalations")"
printf 'DECISIONS WERE PRODUCED THROUGH: handle_wake (the daemon wake consumer)\n'
