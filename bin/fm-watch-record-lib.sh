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

fm_watch_retire_window_records() {  # <state-dir> <window>
  local state=$1 window=$2 key
  [ -n "$window" ] || return 0
  key=$(fm_watch_window_key "$window") || return 1
  rm -f -- \
    "$state/.hash-$key" "$state/.count-$key" "$state/.stale-$key" \
    "$state/.stale-since-$key" "$state/.paused-$key" \
    "$state/.paused-rechecked-$key" "$state/.paused-resurfaced-$key" \
    "$state/.wedge-escalations-$key" "$state/.churn-since-$key" \
    "$state/.writing-since-$key" "$state/.writing-resurfaced-$key"
}
