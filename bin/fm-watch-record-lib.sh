#!/usr/bin/env bash
# Shared ownership of the watcher's per-window record key and retirement.
#
# The watcher and teardown use this helper so a task's cleanup removes exactly
# the records the watcher created for its recorded window.

fm_watch_window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

fm_watch_window_records_unique() {  # <state-dir> <window> <task-id>
  local state=$1 window=$2 task_id=$3 key meta other_id other_window other_key
  [ -n "$window" ] || return 0
  key=$(fm_watch_window_key "$window") || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    other_id=${meta##*/}
    other_id=${other_id%.meta}
    [ "$other_id" != "$task_id" ] || continue
    other_window=$(fm_backend_target_of_meta "$meta") || return 1
    [ -n "$other_window" ] || continue
    other_key=$(fm_watch_window_key "$other_window") || return 1
    if [ "$other_key" = "$key" ]; then
      echo "error: watcher records for $task_id collide with task $other_id; preserving both tasks' watcher records" >&2
      return 1
    fi
  done
}

fm_watch_retire_window_records() {  # <state-dir> <window> <task-id>
  local state=$1 window=$2 task_id=$3 key
  [ -n "$window" ] || return 0
  fm_watch_window_records_unique "$state" "$window" "$task_id" || return 1
  key=$(fm_watch_window_key "$window") || return 1
  rm -f -- \
    "$state/.hash-$key" "$state/.count-$key" "$state/.stale-$key" \
    "$state/.stale-since-$key" "$state/.paused-$key" \
    "$state/.paused-rechecked-$key" "$state/.paused-resurfaced-$key" \
    "$state/.wedge-escalations-$key" "$state/.churn-since-$key" \
    "$state/.writing-since-$key" "$state/.writing-resurfaced-$key"
}
