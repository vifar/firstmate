#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_HOME="$ROOT/.phase-test-tmp/home" FM_STATE_OVERRIDE="$ROOT/.phase-test-tmp/home/state" TMPDIR="$ROOT/.phase-test-tmp"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_HOME/config"
export TMUX="$ROOT/.s,0,0"
unset TMUX_PANE FM_CREW_STATE_BIN FM_FAKE_CREW_STATE
pid=''
cleanup() { if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; tmux -S "$ROOT/.s" kill-server 2>/dev/null || true; }
trap cleanup EXIT
tmux -S "$ROOT/.s" -f /dev/null new-session -d -s phase -n supervisor 'sleep 240'
printf 'backend=tmux\nwindow=phase:fm-oldpause\nworktree=%s/missing\nkind=scout\n' "$FM_HOME" > "$FM_STATE_OVERRIDE/oldpause.meta"
printf 'paused: old external wait\n' > "$FM_STATE_OVERRIDE/oldpause.status"
printf 'working: legacy progress\n' > "$FM_STATE_OVERRIDE/legacy.status"
printf 'CURRENT WORKER STATE\n'
bash bin/fm-crew-state.sh oldpause
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=phase:supervisor FM_POLL=1 FM_HEARTBEAT=2 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=9999 FM_HEARTBEAT_SCAN_SECS=9999
: > "$FM_STATE_OVERRIDE/.afk"
FM_STATE_OVERRIDE="$FM_STATE_OVERRIDE" bash -c '. bin/fm-wake-lib.sh; fm_wake_append stale oldpause "stale: phase:fm-oldpause"; fm_wake_append stale legacy "stale: phase:fm-legacy"'
bash bin/fm-supervise-daemon.sh > "$FM_HOME/daemon.stdout" 2>&1 & pid=$!
for i in $(seq 1 30); do
  if [ -f "$FM_STATE_OVERRIDE/.subsuper-escalations" ] && grep -q 'unidentified pane' "$FM_STATE_OVERRIDE/.subsuper-escalations" && grep -q 'reconcile oldpause' "$FM_STATE_OVERRIDE/.subsuper-escalations"; then break; fi
  sleep 1
done
printf '\nESCALATION BUFFER\n'
cat "$FM_STATE_OVERRIDE/.subsuper-escalations"
printf '\nDAEMON LOG\n'
cat "$FM_STATE_OVERRIDE/.supervise-daemon.log"
printf '\nDURABLE QUEUE STATE\n'
for f in "$FM_STATE_OVERRIDE"/.wake-queue*; do [ -f "$f" ] && { printf '%s\n' "${f##*/}"; cat "$f"; }; done
