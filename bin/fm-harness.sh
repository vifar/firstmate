#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh validate-native-effort <harness> <model> <effort>
#                                        Refuse ultra unless the harness is pi or
#                                        pi-signed and the model explicitly names
#                                        codex-native/<id>. Other efforts retain
#                                        their adapter's existing policy. Native
#                                        Codex validates model support at startup.
#        fm-harness.sh effort-verdict <harness> <model> [<effort>]
#                                        Print "<verdict>\t<source>\t<ladder>\t<listing>".
#                                        This is the single owner of the
#                                        model-aware effort decision: the
#                                        harness-level accepted set, narrowed by
#                                        the model's OWN advertised thinking
#                                        ladder whenever one is readable. An
#                                        unreachable listing establishes nothing,
#                                        so an unreadable ladder is never a
#                                        refusal.
#                                          verdict: supported | unsupported | -
#                                          source:  native           the ultra
#                                                   contract owns it
#                                                   model-ladder     a readable
#                                                   per-model ladder decided it
#                                                   model-undeclared the model is
#                                                   listed but advertises no ladder
#                                                   model-unreadable the ladder
#                                                   could not be read
#                                                   model-unscoped   not a concrete
#                                                   <provider>/<id> selection
#                                                   harness-set      the harness has
#                                                   no per-model ladder surface
#                                                   harness-no-axis  no verified
#                                                   interactive effort axis
#                                          ladder:  comma levels, or -
#                                          listing: omp listing status
#                                                   (listed|listed-undeclared|
#                                                   provider-unlisted|unlisted|
#                                                   not-model|unreadable), or -
#        fm-harness.sh effort-verdicts   Read "<harness>\t<model>\t<effort>" lines on
#                                        stdin and print ONE nested JSON object,
#                                        harness -> model -> effort ->
#                                        supported|unsupported, so a jq config
#                                        validator consults this owner instead of
#                                        restating any effort table. Every
#                                        requested triple gets an entry, and no
#                                        ladder is read twice.
#        fm-harness.sh ancestry [<pid>] print "<strength> <harness>" for the nearest
#                                        harness process at or above <pid> (default this
#                                        process), or nothing when the walk finds none.
#                                        Ancestry evidence only, with no marker layer, so
#                                        a real harness process can be asked what the walk
#                                        makes of it (tests/fm-harness-liveness-drift-live-e2e.test.sh).
#        fm-harness.sh ancestry-descent [<pid>] [<leaf-pid>...]
#                                        print each DISTINCT "<strength> <harness>" the walk
#                                        reaches from the vantages on the UPWARD path
#                                        between the deepest descendant of <pid> and <pid>
#                                        itself, deepest first. Same evidence-only purpose
#                                        as `ancestry`, asked from the vantage point a tool
#                                        subprocess actually occupies rather than from the
#                                        top of the session, which is the only place a
#                                        harness behind an interpreter shim can be seen at
#                                        comm strength. Optional <leaf-pid> values restrict
#                                        which descendants may be chosen as the deepest one,
#                                        so a caller that knows the terminal's foreground
#                                        process group can keep a backgrounded process out
#                                        of the selection.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection evidence and precedence:
#   Markers  - verified environment variables a harness publishes about itself.
#              Cheap and unambiguous about WHICH harness set them, but they are
#              ordinary environment state: a child inherits them, and a terminal
#              multiplexer can replay a stale one into an unrelated session.
#   Ancestry - the nearest harness process in this process's parent chain. This
#              is the structural fact about who actually owns the process tree,
#              so it is what settles a disagreement.
# detect_own is the single owner of how the two combine; harness_marker and
# harness_ancestry only report evidence. Record each newly verified env marker
# in harness_marker, and each newly verified command name in harness_ancestry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "$SCRIPT_DIR/fm-gemini-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# Print the harness named by a verified environment marker, or nothing when no
# marker is present. Markers only report what the environment CLAIMS; detect_own
# decides whether that claim survives contradicting ancestry.
harness_marker() {
  # Cursor is tested BEFORE claude, deliberately. cursor-agent does NOT clear an
  # inherited CLAUDECODE, so a cursor session started by hand from a claude
  # primary carries BOTH markers and whichever is tested first wins. This
  # ordering only settles the case where ancestry finds nothing to arbitrate
  # with; a nearer claude ancestor still outranks both in detect_own.
  # Verified live on cursor-agent 2026.08.11-e8db854: CURSOR_INVOKED_AS=cursor-agent
  # is set on the agent process itself, and CURSOR_AGENT=1 is set for the
  # child/tool processes this script runs as.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  # Gemini is checked BEFORE claude for exactly cursor's reason above: the
  # Gemini CLI does NOT clear an inherited CLAUDECODE, so a gemini worker
  # launched from a claude primary carries BOTH markers and whichever is
  # tested first wins. Verified live on gemini-cli 0.58.0: a tool process
  # spawned by a gemini worker under a claude primary reported GEMINI_CLI=1
  # AND CLAUDECODE=1 together. GEMINI_CLI is gemini's own and is unset in the
  # launching environment, so ordering it first is what makes the verdict
  # correct; bin/fm-spawn.sh additionally clears the foreign markers at the
  # launch boundary. Both are kept for the same reason cursor keeps both.
  # AI_AGENT is deliberately NOT used: it was present in that same process
  # carrying the claude primary's value (claude-code_2-1-260_agent), so it is
  # an inherited launcher marker, not a Gemini identity.
  [ "${GEMINI_CLI:-}" = "1" ] && { echo gemini; return; }
  # rovo (Atlassian Rovo CLI) sets ATLASSIAN_AGENT_TYPE=rovo, ROVODEV_CLI=1, and
  # AGENT=rovodev_cli on its tool subprocesses (verified, rovo 202609.1.2). It does
  # NOT scrub an inherited CLAUDECODE, so a rovo worker launched from a claude
  # session carries both markers - this must be tested BEFORE the CLAUDECODE line,
  # the same ordering hazard cursor documents above (see issue #3517). bin/fm-spawn.sh
  # additionally clears foreign markers at rovo's launch boundary as defense in depth.
  [ "${ATLASSIAN_AGENT_TYPE:-}" = "rovo" ] && { echo rovo; return; }
  [ "${ROVODEV_CLI:-}" = "1" ] && { echo rovo; return; }
  # omp (Oh My Pi) publishes NO harness-identity marker of its own: verified on
  # omp 18.1.11 that PI_CODING_AGENT is absent from the binary and that the
  # default profile sets neither PI_CODING_AGENT_DIR nor OMP_PROFILE in the
  # process environment. FM_OMP_HARNESS=omp is therefore a Firstmate-OWNED
  # launch marker, established by bin/fm-spawn.sh at the omp launch boundary
  # (which also clears every foreign marker) and by the README's primary launch
  # command. It is a PRECEDENCE override, never evidence on its own: it wins
  # over an inherited CLAUDECODE only when an omp process is genuinely in the
  # ancestry, so `FM_OMP_HARNESS=omp omp` started from a Claude pane identifies
  # as omp, while the same variable leaking from an omp secondmate into that
  # home's claude worker (whose ancestry holds no omp) changes nothing. The
  # anchored ancestry arm below covers a plain hand-started `omp` by itself.
  if [ "${FM_OMP_HARNESS:-}" = omp ] && ancestry_names_omp; then
    echo omp
    return
  fi
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok set GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so the marker
  # is unambiguous WHEN PRESENT - but it is not guaranteed present. A grok 1.0.0
  # hook process carries GROK_HOOK_EVENT, GROK_HOOK_NAME, GROK_SESSION_ID, and
  # GROK_WORKSPACE_ROOT with no GROK_AGENT at all (verified from the live process
  # environment of a wedged grok 1.0.0 Stop hook, 2026-08-07). Treat this marker as
  # a fast path only; the ancestry walk below is what actually guarantees grok is
  # identified, and any rule that must be RELIABLE under grok has to test the hook
  # markers too (see .claude/settings.json Stop entries, docs/turnend-guard.md).
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # codex, opencode, kimi, muse, and agy publish no harness-identity marker at all, so
  # they are never named here and are identified by ancestry alone. That is the
  # whole reason a foreign marker must not outrank ancestry: with markers winning
  # unconditionally, any retained CLAUDECODE would silently rename one of them.
  # muse's only documented child variable is MUSE_CURRENT_SESSION_LOG, a
  # per-session log PATH rather than an identity, and its export to tool
  # subprocesses is unverified (verified: muse 0.1.0-R708.1). Do NOT promote it
  # to a marker without verifying it reaches children AND that it cannot survive
  # in a multiplexer's stored environment.
  return 0
}

# True when an exact `omp` process sits within eight parents of this one. The
# same anchored match as the ancestry walk below, kept separate so the marker
# precedence above can demand real process evidence before trusting FM_OMP_HARNESS.
ancestry_names_omp() {
  local pid=$$ comm
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [ "$(basename -- "$comm")" = omp ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Print "<strength> <harness>" when one process identifies a harness, or nothing.
# Strength records how the match was made:
#   comm - the ancestor's own executable name identifies the harness. This is a
#          structural fact about the running program, so it outranks a marker.
#   args - a bare interpreter matched only because a harness name appears in the
#          script path it was handed. This is the weakest inference in this file
#          (any node process holding a harness-shaped path matches it), so it is
#          used only when no marker is present.
harness_process_verdict() {  # <pid>
  local pid=$1 comm args argv0
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
  if fm_cursor_process_matches "$comm" '' "$argv0"; then
    echo "comm cursor"
    return
  fi
  if fm_gemini_path_is_gemini "$comm"; then
    echo "comm gemini"
    return
  fi
  case "$(basename -- "$comm")" in
    # gemini precedes claude here for the same precedence reason as the
    # marker layer above, so a gemini worker under a claude primary is never
    # read as claude. This arm covers a natively-named gemini binary only.
    # It does NOT reach the currently installed CLI, which is a node bundle
    # (~/.local/bin/gemini -> @google/gemini-cli/bundle/gemini.js): modern
    # Node on Linux reports `comm` as MainThread rather than node (measured
    # on Node v24.20.0), so neither this arm nor the node interpreter arm
    # below matches a live gemini process. GEMINI_CLI above is therefore
    # load-bearing for gemini rather than a fast path, which is why gemini
    # is not offered as a primary or secondmate harness. Do NOT add
    # MainThread to the interpreter arm to close this: that would make the
    # args of EVERY node process searchable and let an unrelated node
    # command carrying a harness name in its arguments claim an identity.
    *claude*) echo "comm claude"; return ;;
    *codex*) echo "comm codex"; return ;;
    *opencode*) echo "comm opencode"; return ;;
    *grok*) echo "comm grok"; return ;;
    kimi) echo "comm kimi"; return ;;
    rovo) echo "comm rovo"; return ;;
      # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
      # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
      # name carries the version and CHANGES on every auto-update. Match the stable
      # prefix rather than any exact name. Deliberately anchored, never *muse*, so
      # unrelated commands (musescore, amuse) cannot be misread as this harness.
    muse|muse-bin-*) echo "comm muse"; return ;;
    # Both Pi identities share this launcher name. Ancestry can only prove the
    # FAMILY; only the launch-boundary marker selects the signed identity, which
    # is why detect_own keeps a marker that agrees on the family.
    pi-signed) echo "comm pi"; return ;;
    pi) echo "comm pi"; return ;;
    # omp is a Bun-compiled single binary whose process name is exactly `omp`
    # (verified, omp 18.1.11: `ps -o comm=` reports omp from both its `!`
    # bash path and the model's bash tool). Anchored, never *omp*, so ompd,
    # comp, and similar unrelated commands are not misread as this harness.
    # It sits above the node*|python* interpreter fallback deliberately: the
    # optional claude-bridge extension runs a nested executable literally
    # named `claude` with its own node child, and that fallback's *claude*
    # args glob would otherwise claim it if that subtree were ever walked.
    omp) echo "comm omp"; return ;;
    # agy (Antigravity CLI) is a Go-compiled single binary whose process name
    # is exactly `agy` (verified, agy 1.2.0: `ps -o comm=` reports agy and
    # Herdr's process-info reports name agy with argv[0] agy). Anchored, never
    # *agy*, so unrelated commands cannot be misread as this harness. agy
    # publishes no harness-identity marker of its own (a live 1.2.0 TUI
    # carries no AGY_* or ANTIGRAVITY_* variable; AGENT=1 seen there is an
    # inherited launcher value, not an agy identity), so like muse it is
    # detected by ancestry alone.
    agy) echo "comm agy"; return ;;
    node*|python*)
      # Bare interpreter: match the harness name in its script path.
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      if fm_gemini_args_are_gemini "$args"; then
        echo "args gemini"
        return
      fi
      case "$args" in
        *claude*) echo "args claude"; return ;;
        *codex*) echo "args codex"; return ;;
        *opencode*) echo "args opencode"; return ;;
        *grok*) echo "args grok"; return ;;
        *" pi "*|*/pi) echo "args pi"; return ;;
      esac ;;
  esac
}

# Print the verdict for the NEAREST harness process in the parent chain, or
# nothing when the walk finds none. The nearest match wins, so a worker nested
# inside another harness resolves to its own harness.
harness_ancestry() {  # [<pid>]
  local pid=${1:-$$} verdict
  for _ in 1 2 3 4 5 6 7 8; do
    verdict=$(harness_process_verdict "$pid")
    [ -z "$verdict" ] || { echo "$verdict"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Stop only once the walk has EXAMINED the top of the chain. Inside a PID
    # namespace the harness itself is pid 1 - a container, or the `codex sandbox`
    # this boundary was proven in - so breaking as soon as the next pid is 1
    # skips the one process that identifies the session and hands the verdict
    # straight back to a retained marker. A host's real pid 1 (init, systemd,
    # launchd) matches no harness name above, so examining it costs one ps call
    # and can introduce no false positive.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 0
}

# Print the pids on the UPWARD path between the deepest descendant of <root> and
# <root> itself, deepest first. Optional <eligible-leaf-pid> values restrict which
# descendants may be chosen as that deepest one; with none given every descendant
# is eligible. Bounded to the same eight levels harness_ancestry climbs, so a deep
# or pathological tree cannot make this walk unbounded.
process_descent_path() {  # <root> [<eligible-leaf-pid>...]
  local root=${1:-$$} eligible any hit pairs frontier next pid child parent verdict
  local parents='' depth=0 best best_depth=0 best_strength='' hops=0
  case "$root" in '' | *[!0-9]*) return 0 ;; esac
  shift 2>/dev/null || true
  eligible=" ${*+$*} "
  any=0
  [ "$#" -eq 0 ] && any=1
  pairs=$(ps -eo pid=,ppid= 2>/dev/null) || { printf '%s\n' "$root"; return 0; }
  best=$root
  frontier=$root
  while [ -n "$frontier" ] && [ "$depth" -lt 8 ]; do
    next=
    for pid in $frontier; do
      while read -r child parent; do
        [ "$parent" = "$pid" ] || continue
        [ "$child" != "$pid" ] || continue
        parents="$parents $child:$pid"
        next="$next $child"
        if [ "$any" = 1 ]; then
          hit=1
        else
          case "$eligible" in
            *" $child "*) hit=1 ;;
            *) hit=0 ;;
          esac
        fi
        if [ "$hit" = 1 ]; then
          verdict=$(harness_process_verdict "$child")
          if [ $((depth + 1)) -gt "$best_depth" ]; then
            best=$child
            best_depth=$((depth + 1))
            best_strength=${verdict%% *}
          # At equal depth, prefer the leaf whose own executable reaches comm
          # strength. Otherwise an earlier MCP interpreter carrying a foreign
          # harness path can hide a native harness sibling purely through ps
          # ordering. This repairs the chosen path's comm-strength guarantee;
          # args-strength foreign verdicts remain excluded from cross-checking.
          elif [ $((depth + 1)) -eq "$best_depth" ] \
            && [ "$best_strength" != comm ] && [ "${verdict%% *}" = comm ]; then
            best=$child
            best_strength='comm'
          fi
        fi
      done <<EOF
$pairs
EOF
    done
    frontier=$next
    depth=$((depth + 1))
  done

  pid=$best
  while [ -n "$pid" ] && [ "$hops" -le 8 ]; do
    printf '%s\n' "$pid"
    [ "$pid" != "$root" ] || break
    parent=
    case "$parents" in
      *" $pid:"*)
        parent=${parents##*" $pid:"}
        parent=${parent%% *} ;;
    esac
    pid=$parent
    hops=$((hops + 1))
  done
}

# Print each DISTINCT "<strength> <harness>" verdict harness_ancestry reaches from
# the vantages on the upward path between the deepest descendant of <root> and
# <root>, one per line, deepest first.
#
# Why a descent path and not <root> alone: detect_own always runs from a TOOL
# SUBPROCESS inside a session, never from the process at the top of it, and that
# difference decides whether a retained foreign marker can rename the session. A
# harness that ships as an interpreter shim spawning its native binary as a CHILD
# is only args strength when asked from the shim, and detect_own hands an
# args-strength verdict straight back to the marker; the native child is comm
# strength and outranks it. Asking from below is what puts the question at the
# vantage point a real session uses, so a guard built on this can assert the
# strength the shipped guarantee actually depends on
# (tests/fm-harness-liveness-drift-live-e2e.test.sh).
#
# Why the upward path and not the whole subtree: harness_ancestry only ever climbs,
# so a SIBLING branch is a vantage firstmate's own detection can never occupy. A
# harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js` matches
# *claude* on its script path in the bare-interpreter branch above and would report a
# foreign harness from a process no real tool subprocess ever asks from.
harness_ancestry_descent() {  # <root> [<eligible-leaf-pid>...]
  local pid verdict seen=
  for pid in $(process_descent_path "$@"); do
    verdict=$(harness_ancestry "$pid")
    [ -n "$verdict" ] || continue
    case "$seen" in *"|$verdict|"*) continue ;; esac
    seen="$seen|$verdict|"
    printf '%s\n' "$verdict"
  done
}

# Collapse a verdict to the harness FAMILY its evidence can actually prove, so a
# marker's more specific verdict and ancestry's coarser one are not read as a
# disagreement. Only Pi has two identities behind one launcher name.
harness_family() {
  case "$1" in
    pi-signed) printf 'pi\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Combine the two evidence layers. The precedence boundary, in one rule: a
# marker names its harness, but only ancestry proves which harness owns this
# process tree, so a structural (comm) ancestor of a DIFFERENT harness wins.
#   - No ancestry match: the marker is the only evidence there is.
#   - No marker: ancestry is the only evidence there is.
#   - Same family: keep the marker's verdict, which is the more specific one
#     (pi-signed, which ancestry can only see as pi).
#   - Different harness, structural ancestor: ancestry wins. This is what stops
#     an inherited or multiplexer-retained CLAUDECODE from renaming a markerless
#     codex, opencode, kimi, or muse session, and symmetrically stops a retained
#     CURSOR_AGENT from renaming a claude worker nested under cursor.
#   - Different harness, interpreter-args ancestor only: the marker wins, because
#     a harness-shaped path in some node process's arguments is weaker evidence
#     than a harness publishing its own identity.
detect_own() {
  local marker ancestry strength harness
  marker=$(harness_marker)
  ancestry=$(harness_ancestry)
  if [ -z "$ancestry" ]; then
    if [ -n "$marker" ]; then echo "$marker"; else echo unknown; fi
    return
  fi
  strength=${ancestry%% *}
  harness=${ancestry#* }
  [ -n "$marker" ] || { echo "$harness"; return; }
  if [ "$(harness_family "$marker")" = "$(harness_family "$harness")" ]; then
    echo "$marker"
    return
  fi
  if [ "$strength" = comm ]; then echo "$harness"; else echo "$marker"; fi
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

validate_native_effort() {
  local harness=${1:-} model=${2:-} effort=${3:-}
  [ "$effort" = ultra ] || return 0
  case "$harness" in
    pi|pi-signed)
      case "$model" in codex-native/?*) return 0 ;; esac
      ;;
  esac
  echo "error: ultra effort requires pi or pi-signed with an explicit codex-native/<model> model" >&2
  return 1
}

# ---- model-aware effort ladder owner ------------------------------------------
#
# The single owner of the effort axis. The harness-level accepted sets, the
# per-model ladder read, and the rule that combines them live here and nowhere
# else: bin/fm-spawn.sh asks `effort-verdict` before it emits any effort flag,
# and bin/fm-dispatch-resolve.sh and bin/fm-bootstrap.sh ask `effort-verdicts`
# once per config instead of restating an effort table in jq.
#
# Why this exists: a requested effort used to be checked only against the
# harness's accepted set. A standing config asking for `medium` on a model whose
# advertised ladder is low,high,max therefore passed validation, was recorded as
# `effort=medium`, and launched with no warning, so the recorded intent silently
# overstated what the model could honour. The model's own advertised ladder now
# decides, and a contradiction is reported rather than passed over.
#
# An unreachable surface establishes nothing (references/common/model-and-effort.md):
# a ladder that cannot be read leaves the harness-level set in force, so an
# unreadable listing never becomes a refusal.

# The harness-level accepted set for <harness> as space-separated levels, or
# non-zero when this owner declares no axis for it (the caller then inherits the
# permissive shared vocabulary, exactly as the previous per-harness verdicts
# did). `ultra` appears in no set: the native contract above contributes it, so
# no set restates that rule. An empty set is a harness with no verified
# interactive effort axis, which accepts nothing.
harness_effort_set() {  # <harness>
  case "${1:-}" in
    claude | omp | muse | pi | pi-signed) printf '%s\n' 'low medium high xhigh max' ;;
    codex) printf '%s\n' 'low medium high xhigh' ;;
    grok | agy) printf '%s\n' 'low medium high' ;;
    rovo) printf '%s\n' 'low medium high max' ;;
    opencode | kimi | cursor) printf '%s\n' '' ;;
    *) return 1 ;;
  esac
}

# Print the extra levels <harness> declares for one <model> in its own adapter
# contract, space separated. These are declared facts, not catalog copies: they
# stay in force whether or not a ladder could be read, because a declared
# capability is what the verified adapter reference established.
harness_model_levels() {  # <harness> <model>
  case "${1:-}" in
    codex)
      # references/harness/codex.md: the installed catalog advertises max for
      # gpt-5.6-luna, and firstmate passes it for that model.
      case "${2:-}" in gpt-5.6-luna) printf '%s\n' 'max' ;; esac
      ;;
  esac
  return 0
}

levels_contains() {  # <levels> <level>
  local lvl
  for lvl in $1; do
    [ "$lvl" = "$2" ] && return 0
  done
  return 1
}

levels_union() {  # <levels> <levels>
  local out=$1 lvl
  for lvl in $2; do
    levels_contains "$out" "$lvl" || out="$out $lvl"
  done
  printf '%s\n' "${out# }"
}

levels_intersect() {  # <levels> <levels>
  local out='' lvl
  for lvl in $1; do
    levels_contains "$2" "$lvl" && out="$out $lvl"
  done
  printf '%s\n' "${out# }"
}

levels_json() {  # <levels> -> a JSON array on one line
  local out='[]' lvl
  for lvl in $1; do
    out=$(printf '%s' "$out" | jq -c --arg l "$lvl" '. + [$l]' 2>/dev/null) || out='[]'
  done
  printf '%s\n' "$out"
}

# Print `omp models --json` verbatim, or nothing when it cannot be read. Cached
# for the life of the process, so answering many pairs costs one probe. A stalled
# vendor CLI must never block a spawn or a session start, so the probe runs under
# the shared hard bound, and any failure is reported as unreadable.
#
# FM_OMP_BIN lets a caller that already resolved the executable (bin/fm-spawn.sh)
# pin the exact binary this owner probes, so the catalog read stays one code path
# rather than one per resolved caller.
OMP_MODELS_RAW_READ=0
OMP_MODELS_RAW=
omp_models_raw() {
  [ "$OMP_MODELS_RAW_READ" = 1 ] && { printf '%s' "$OMP_MODELS_RAW"; return 0; }
  OMP_MODELS_RAW_READ=1
  local bin=${FM_OMP_BIN:-}
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$bin" ] || bin=$(command -v omp 2>/dev/null) || return 0
  [ -n "$bin" ] || return 0
  [ -x "$bin" ] || return 0
  OMP_MODELS_RAW=$(OMP_SKIP_SETUP=1 fm_run_timed "${FM_OMP_MODELS_TIMEOUT:-10}" "$bin" models --json 2>/dev/null) || OMP_MODELS_RAW=
  printf '%s' "$OMP_MODELS_RAW"
}

# Print "<listing-status>\t<advertised levels, comma separated or ->" for one omp
# model selection. The ONLY reader of the omp catalog shape, scoped to exactly
# what that listing can prove:
#   listed             listed, with the thinking ladder in the second field
#   listed-undeclared  listed, but advertising no thinking ladder at all
#   provider-unlisted  the provider is absent from the listing
#   unlisted           absent although its provider is listed
#   not-model          not a concrete <provider>/<id> selection
#   unreadable         the listing could not be read
omp_model_ladder() {  # <model>
  local model=${1:-} listing providers levels
  [ -n "$model" ] && [ "$model" != default ] && [ "$model" != - ] || { printf 'not-model\t-\n'; return 0; }
  case "$model" in */*) ;; *) printf 'not-model\t-\n'; return 0 ;; esac
  listing=$(omp_models_raw)
  [ -n "$listing" ] || { printf 'unreadable\t-\n'; return 0; }
  providers=$(printf '%s' "$listing" | jq -r '.models[]?.provider // empty' 2>/dev/null | sort -u) || providers=
  [ -n "$providers" ] || { printf 'unreadable\t-\n'; return 0; }
  if ! printf '%s\n' "$providers" | grep -qxF -- "${model%%/*}"; then
    printf 'provider-unlisted\t-\n'
    return 0
  fi
  if printf '%s' "$listing" | jq -e --arg m "$model" '.models[]? | select(.selector == $m)' >/dev/null 2>&1; then
    levels=$(printf '%s' "$listing" | jq -r --arg m "$model" \
      '[.models[]? | select(.selector == $m) | (.thinking // [])[]] | join(",")' 2>/dev/null) || levels=
    if [ -n "$levels" ]; then printf 'listed\t%s\n' "$levels"; else printf 'listed-undeclared\t-\n'; fi
    return 0
  fi
  printf 'unlisted\t-\n'
}

# Print "<source>\t<ladder>\t<listing>\t<effective levels>" for <harness> <model>.
# The single place the harness set, the readable per-model ladder, the declared
# per-model levels, and the native ultra contract combine.
#   source  no-opinion       no declared axis: the shared vocabulary applies
#           harness-no-axis  the harness exposes no verified effort axis
#           harness-set      the harness set decided, with no readable ladder
#           model-ladder     the model's own advertised ladder narrowed it
#           model-undeclared listed, but the model advertises no ladder
#           model-unreadable the model's ladder could not be read
#           model-unscoped   not a concrete <provider>/<id> selection
#   ladder  the model's advertised levels as evidence, or -
#   listing the omp model-listing status above, or -
effort_levels_for() {  # <harness> <model>
  local harness=${1:-} model=${2:-} set src ladder='-' listing='-' read_out
  [ -n "$model" ] && [ "$model" != default ] || model=-
  if set=$(harness_effort_set "$harness"); then
    if [ -n "$set" ]; then src="harness-set"; else src="harness-no-axis"; fi
  else
    src="no-opinion"
    set='low medium high xhigh max'
  fi
  # omp is the verified harness whose per-model ladder is readable from a CLI
  # listing; every other adapter's effort axis is model-independent or unknown.
  if [ "$harness" = omp ] && [ "$src" != harness-no-axis ]; then
    read_out=$(omp_model_ladder "$model")
    listing=${read_out%%$'\t'*}
    ladder=${read_out#*$'\t'}
    case "$listing" in
      listed)
        set=$(levels_intersect "$set" "$(printf '%s' "$ladder" | tr ',' ' ')")
        src="model-ladder"
        ;;
      listed-undeclared) src="model-undeclared"; ladder='-' ;;
      unreadable | provider-unlisted | unlisted) src="model-unreadable"; ladder='-' ;;
      *) src="model-unscoped"; ladder='-' ;;
    esac
  fi
  set=$(levels_union "$set" "$(harness_model_levels "$harness" "$model")")
  if validate_native_effort "$harness" "$model" ultra 2>/dev/null; then
    set=$(levels_union "$set" ultra)
  fi
  printf '%s\t%s\t%s\t%s\n' "$src" "$ladder" "$listing" "$set"
}

# Print "<verdict>\t<source>\t<ladder>\t<listing>". The verdict answers the
# launch question - may this level reach this model - and the rest carries the
# evidence a caller reports. An empty <effort> reports the model and listing
# verdicts with no effort verdict, which is what a caller with no requested level
# wants to know.
effort_verdict() {  # <harness> <model> [<effort>]
  local harness=${1:-} model=${2:-} effort=${3:-} fields src ladder listing set verdict='-'
  [ -n "$effort" ] && [ "$effort" != default ] || effort=
  fields=$(effort_levels_for "$harness" "$model")
  IFS=$'\t' read -r src ladder listing set <<<"$fields"
  if [ -n "$effort" ]; then
    if levels_contains "$set" "$effort"; then verdict=supported; else verdict=unsupported; fi
    [ "$effort" = ultra ] && src=native
  fi
  printf '%s\t%s\t%s\t%s\n' "$verdict" "$src" "$ladder" "$listing"
}

# Read "<harness>\t<model>\t<effort>" lines on stdin and print ONE nested JSON
# object, harness -> model -> effort -> "supported" | "unsupported", so a jq
# config validator consults this owner instead of restating any effort table.
# The "*" harness key is the permissive shared vocabulary for a harness this
# owner declares no axis for. Every requested triple gets an entry, and each
# model's ladder is read once no matter how many levels are asked about.
effort_verdicts() {
  local harness model effort fields set verdict entry
  entry='{"*":{"*":{"low":"supported","medium":"supported","high":"supported","xhigh":"supported","max":"supported"}}}'
  while IFS=$'\t' read -r harness model effort || [ -n "$harness" ]; do
    [ -n "$harness" ] || continue
    [ -n "$model" ] || model=-
    [ -n "$effort" ] || effort=-
    fields=$(effort_levels_for "$harness" "$model")
    set=${fields##*$'\t'}
    if [ "$effort" = - ]; then verdict=supported
    elif levels_contains "$set" "$effort"; then verdict=supported
    else verdict=unsupported
    fi
    entry=$(printf '%s' "$entry" | jq -c --arg h "$harness" --arg m "$model" \
      --arg e "$effort" --arg v "$verdict" \
      '.[$h] = ((.[$h] // {}) | .[$m] = ((.[$m] // {}) + {($e): $v}))') || return 1
  done
  printf '%s\n' "$entry"
}

case "${1:-}" in
  validate-native-effort) shift; validate_native_effort "$@" ;;
  effort-verdict) shift; effort_verdict "$@" ;;
  effort-verdicts) effort_verdicts ;;
  ancestry)
    case "${2:-}" in
      ''|*[!0-9]*) [ -z "${2:-}" ] || { echo "error: ancestry takes a numeric pid" >&2; exit 2; } ;;
    esac
    harness_ancestry "${2:-$$}"
    ;;
  ancestry-descent)
    shift
    for arg in ${1+"$@"}; do
      case "$arg" in
        ''|*[!0-9]*) echo "error: ancestry-descent takes numeric pids" >&2; exit 2 ;;
      esac
    done
    descent_pid="${1:-$$}"
    [ "$#" -eq 0 ] || shift
    harness_ancestry_descent "$descent_pid" ${1+"$@"}
    ;;
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  *) detect_own ;;
esac
