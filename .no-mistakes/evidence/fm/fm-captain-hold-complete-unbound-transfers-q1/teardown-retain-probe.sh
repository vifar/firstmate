#!/usr/bin/env bash
# Manual reproduction of the pre-existing teardown retention failure observed in
# tests/fm-captain-hold-lifecycle.test.sh on this macOS host.
set -u
REPO=${REPO:-/Users/king/.no-mistakes/worktrees/af95b24e5115/01M3CSTMAMNT011QAV1TBM9N3C}
TASKS_AXI_BIN=$(command -v tasks-axi || true)
. "$REPO/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-repro-teardown)
make_home() {
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
run_captain() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$REPO/bin/fm-captain-hold.sh" "$@"
}
run_teardown() {
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$REPO" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$REPO/bin/fm-teardown.sh" "$id"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@"); }

home=$(make_home nonref-default)
id=sample-nonref-scout
mkdir -p "$home/data/$id"
tasks_in "$home" add "$id" "Investigate the sample body decode" --kind scout \
  --repo sample --start >/dev/null || { echo "add failed"; exit 1; }
fm_write_meta "$home/state/$id.meta" \
  "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
  "project=$home/projects/sample" "harness=codex" "kind=scout" "mode=scout" \
  "spawn_gen=fixture-$id"
printf 'done: report complete\n' > "$home/state/$id.status"
printf '# Sample body decode\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null || { echo "hold failed"; exit 1; }
run_captain "$home" complete "$id" "$id" || { echo "complete failed"; exit 1; }
echo "=== teardown stdout/stderr ==="
run_teardown "$home" "$id"
echo "teardown_exit=$?"
echo "=== backlog.md after teardown ==="
sed -n '1,60p' "$home/data/backlog.md"
echo "=== data_relative probe ==="
bash -c '. "$1"; fm_backlog_data_relative "$2"' _ "$REPO/bin/fm-backlog-transition-lib.sh" "$home/data" || echo "(probe failed)"

echo "=== backlog transition gate probe ==="
CONFIG="$home/config" DATA="$home/data" KIND=scout
bash -c '
  set -u
  . "$1"
  if fm_backlog_transition_applies "$2" "$3" "$4"; then
    echo "applies=yes"
  else
    rc=$?
    echo "applies=no rc=$rc skip=[$FM_BACKLOG_TRANSITION_SKIP] err=[$FM_BACKLOG_TRANSITION_ERROR]"
  fi
' _ "$REPO/bin/fm-backlog-transition-lib.sh" "$CONFIG" "$DATA" "$KIND"
