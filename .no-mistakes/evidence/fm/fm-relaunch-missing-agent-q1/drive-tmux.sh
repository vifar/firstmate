#!/bin/bash
set -eu
ROOT=$PWD
LAB=$ROOT/.relaunch-live
EVID=/Users/king/.no-mistakes/evidence/01M2JKQ6400YDF9J9F7SPEKC5X
mkdir -p "$LAB/home/state" "$LAB/home/data/live-missing" "$LAB/user" "$LAB/codex" "$LAB/shim"
export HOME="$LAB/user" CODEX_HOME="$LAB/codex" FM_HOME="$LAB/home" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cat > "$LAB/shim/tmux" <<EOF
#!/bin/bash
exec /opt/homebrew/bin/tmux -S "$LAB/socket" "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
trap 'tmux kill-server 2>/dev/null || true' EXIT
git init -q "$LAB/project"
git -C "$LAB/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm seed
git -C "$LAB/project" worktree add -qb interrupted "$LAB/wt"
printf 'unfinished work\n' > "$LAB/wt/unfinished.txt"
mkdir -p "$FM_HOME/state/live-missing.inbox"
printf 'pending instruction\n' > "$FM_HOME/state/live-missing.inbox/1"
printf '# Task\nRemain idle. This is a terminal recovery test. Do not run commands or modify files.\n' > "$FM_HOME/data/live-missing/brief.md"
cat > "$FM_HOME/state/live-missing.meta" <<EOF
window=live:fm-live-missing
endpoint_task_id=live-missing
worktree=$LAB/wt
project=$LAB/project
harness=codex
kind=ship
mode=direct-PR
yolo=off
model=default
effort=default
EOF
tmux -f /dev/null new-session -d -s live -n keeper -c "$LAB/wt"
tmux set-option -g default-shell /bin/bash
echo 'BEFORE: recorded task endpoint is absent; keeper window exists'
tmux list-windows -t live -F '#{window_name}'
FM_CONTROL_LAUNCH_WAIT=15 "$ROOT/bin/fm-control.sh" live-missing relaunch --note 'Preserve unfinished work and pending steering.'
echo 'AFTER: endpoint and current directory'
tmux list-panes -a -F '#{window_name} #{pane_current_path} #{pane_current_command}'
echo 'PRESERVED CONTENTS'
cat "$LAB/wt/unfinished.txt" "$FM_HOME/state/live-missing.inbox/1"
echo 'PERSISTED RECORD'
cat "$FM_HOME/state/live-missing.meta"
echo 'STOPPED SERVER RECOVERY'
tmux kill-server
FM_CONTROL_LAUNCH_WAIT=15 "$ROOT/bin/fm-control.sh" live-missing relaunch --note 'Recover after server loss; preserve the same work.'
tmux list-panes -a -F '#{window_name} #{pane_current_path} #{pane_current_command}'
cat "$LAB/wt/unfinished.txt" "$FM_HOME/state/live-missing.inbox/1"
echo 'DIRECT RELAUNCH INTO LIVE AGENT (must refuse)' 
set +e
"$ROOT/bin/fm-spawn.sh" live-missing --relaunch --harness codex
rc=$?
set -e
echo "direct_spawn_exit=$rc"
[ "$rc" = 1 ]
tmux capture-pane -p -t live:fm-live-missing > "$EVID/codex-terminal.txt"
