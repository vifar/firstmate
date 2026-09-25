#!/usr/bin/env bash
# tests/fm-harness-effort-ladder.test.sh - the model-aware effort axis.
#
# The defect this pins: a requested effort used to be validated only against the
# HARNESS's accepted set. config/crew-dispatch.json therefore asked for `medium`
# on omp, every live worker lane ran vibeproxy/deepseek-v4.1-flash whose
# advertised ladder is low|high|max, the config passed validation, the spawn
# recorded effort=medium in task metadata, and omp launched with no warning. The
# recorded intent silently overstated what the model could honour and nothing
# reported it.
#
# The contract now: bin/fm-harness.sh is the single owner of the effort axis
# (`effort-verdict` / `effort-verdicts`), the model's OWN advertised thinking
# ladder narrows the harness set, an unsupported level is surfaced LOUDLY and
# omitted from the launch flags (record-and-omit, as a harness-level mismatch
# already was), the task record adds effort_applied= so it cannot overstate the
# request, an unreadable ladder is NEVER a refusal, and `ultra` keeps its own
# native contract.
#
# Every case drives a FIXTURE omp catalog (never a live network call), so the
# ladder under test is stated by the test rather than by the workstation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
DISPATCH="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-effort-ladder)

# --- the owner ---------------------------------------------------------------

# A fixture omp. `models --json` prints exactly <json> (delivered through a
# sidecar file so no shell quoting can mangle it); any other invocation emulates
# the per-task omp extension by recording an agent_start busy event for the task
# named by its own -e wiring. That emit is load-bearing: fm-spawn's post-launch
# readiness gate waits for exactly that event, and arming the busy contract
# replaces any pre-seeded record, so a fixture that only exits 0 leaves the gate
# waiting out its bound. FM_OMP_BIN pins this binary as the one the effort owner
# probes, so no case depends on install state.
write_fake_omp() {  # <dir> <json>
  local dir=$1 json=$2
  mkdir -p "$dir"
  printf '%s\n' "$json" > "$dir/models.json"
  cat > "$dir/omp" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  cat "$(dirname "$0")/models.json"
  exit 0
fi
ext='' prev=''
for a in "$@"; do
  [ "$prev" = -e ] && ext=$a
  prev=$a
done
if [ -n "$ext" ]; then
  state=${ext%/*}; base=${ext##*/}; id=${base%.omp-ext.ts}
  gen=''
  [ -f "$state/$id.busy-gen" ] && gen=$(cat "$state/$id.busy-gen")
  printf 'v1 gen=%s seq=2 state=busy source=omp-ext event=agent_start ts=%s\n' \
    "$gen" "$(date +%s)" > "$state/$id.busy-state" 2>/dev/null
fi
exit 0
SH
  chmod +x "$dir/omp"
  printf '%s\n' "$dir/omp"
}

# The two ladders the defect was observed on: the captain's live worker model
# advertises low|high|max (no medium), while a sibling model advertises all five.
CATALOG_DEEPSEEK='{"models":[{"provider":"vibeproxy","id":"deepseek-v4.1-flash","selector":"vibeproxy/deepseek-v4.1-flash","thinking":["low","high","max"]},{"provider":"vibeproxy","id":"gpt-6-luna","selector":"vibeproxy/gpt-6-luna","thinking":["low","medium","high","xhigh","max"]}]}'

owner_verdict() {  # <omp-bin> <harness> <model> <effort>
  FM_OMP_BIN="$1" "$HARNESS" effort-verdict "$2" "$3" "$4" 2>/dev/null
}

test_owner_narrows_harness_set_by_model_ladder() {
  local fake out
  fake=$(write_fake_omp "$TMP_ROOT/owner" "$CATALOG_DEEPSEEK")

  # The real observed mismatch: medium is in omp's accepted set but absent from
  # this model's advertised ladder, so it must come back unsupported.
  out=$(owner_verdict "$fake" omp vibeproxy/deepseek-v4.1-flash medium)
  [ "$(printf '%s' "$out" | cut -f1)" = unsupported ] \
    || fail "medium must be unsupported by a low|high|max model (got '$out')"
  [ "$(printf '%s' "$out" | cut -f2)" = model-ladder ] \
    || fail "the verdict must be attributed to the model's ladder (got '$out')"
  [ "$(printf '%s' "$out" | cut -f3)" = low,high,max ] \
    || fail "the advertised ladder must be reported as evidence (got '$out')"

  # A level the model does advertise stays supported.
  out=$(owner_verdict "$fake" omp vibeproxy/deepseek-v4.1-flash high)
  assert_equals supported "$(printf '%s' "$out" | cut -f1)" "high must be supported by a low|high|max model"

  # xhigh is absent from the observed model too, and present on the sibling: the
  # decision is per-model, not per-harness.
  out=$(owner_verdict "$fake" omp vibeproxy/deepseek-v4.1-flash xhigh)
  assert_equals unsupported "$(printf '%s' "$out" | cut -f1)" "xhigh must be unsupported by a low|high|max model"
  out=$(owner_verdict "$fake" omp vibeproxy/gpt-6-luna xhigh)
  assert_equals supported "$(printf '%s' "$out" | cut -f1)" "xhigh must stay supported by a model that advertises it"

  pass "owner: the model's advertised ladder narrows the harness accepted set"
}

test_owner_never_refuses_on_unreadable_or_absent_ladder() {
  local fake out

  # An EMPTY listing is what this workstation actually returns after a vendor
  # catalog rebuild, and it must establish nothing: omp's accepted set stays in
  # force so `medium` is not refused on evidence that does not exist.
  fake=$(write_fake_omp "$TMP_ROOT/empty" '{"models":[]}')
  out=$(owner_verdict "$fake" omp vibeproxy/deepseek-v4.1-flash medium)
  assert_equals supported "$(printf '%s' "$out" | cut -f1)" "an empty listing must not refuse a level"
  assert_equals model-unreadable "$(printf '%s' "$out" | cut -f2)" "an empty listing must be reported unreadable"

  # A model listed with no thinking ladder at all is its own case: the harness
  # set still stands rather than being read as "nothing is supported".
  fake=$(write_fake_omp "$TMP_ROOT/undeclared" '{"models":[{"provider":"vibeproxy","id":"opaque","selector":"vibeproxy/opaque"}]}')
  out=$(owner_verdict "$fake" omp vibeproxy/opaque medium)
  assert_equals supported "$(printf '%s' "$out" | cut -f1)" "a model with no declared ladder must not refuse a level"
  assert_equals model-undeclared "$(printf '%s' "$out" | cut -f2)" "an undeclared ladder must be reported as its own case"

  # A provider the listing does not know (extension-registered providers are
  # never listed) is likewise no evidence against the level.
  out=$(owner_verdict "$fake" omp claude-bridge/claude-opus-4-8 medium)
  assert_equals supported "$(printf '%s' "$out" | cut -f1)" "an unlisted provider must not refuse a level"

  pass "owner: an unreadable, undeclared, or unlisted ladder is never a refusal"
}

test_owner_preserves_ultra_contract() {
  local out

  # ultra is the pre-existing native contract: supported only for pi/pi-signed
  # with a codex-native/<id> model, and never inferred by any ladder.
  out=$(owner_verdict /nonexistent omp vibeproxy/deepseek-v4.1-flash ultra)
  assert_equals unsupported "$(printf '%s' "$out" | cut -f1)" "ultra must stay unsupported on omp"
  out=$(owner_verdict /nonexistent pi codex-native/gpt-5.6-luna ultra)
  assert_equals supported "$(printf '%s' "$out" | cut -f1)" "ultra must stay supported for pi with a codex-native model"
  out=$(owner_verdict /nonexistent pi openai-codex/gpt-6-astra ultra)
  assert_equals unsupported "$(printf '%s' "$out" | cut -f1)" "ultra must stay unsupported for pi with a non-codex-native model"

  pass "owner: the ultra native contract is unchanged"
}

# --- the config validator ----------------------------------------------------

# A dispatch config asking for <effort> on the observed model, in the shape the
# real config uses (rule + default), so the validator path is exercised rather
# than a hand-built fragment.
write_dispatch_config() {  # <dir> <effort>
  mkdir -p "$1"
  cat > "$1/crew-dispatch.json" <<EOF
{
  "rules": [
    {
      "when": "Narrow ship: implement a bounded, well-specified change with no open design.",
      "use": { "harness": "omp", "model": "vibeproxy/deepseek-v4.1-flash", "effort": "$2", "provider": "vibeproxy" },
      "why": "fixture"
    }
  ],
  "default": [ { "harness": "omp", "model": "vibeproxy/deepseek-v4.1-flash", "effort": "$2", "provider": "vibeproxy" } ]
}
EOF
}

test_dispatch_config_rejects_the_observed_mismatch() {
  local home fake out status
  home="$TMP_ROOT/dispatch"
  fake=$(write_fake_omp "$TMP_ROOT/dispatch-bin" "$CATALOG_DEEPSEEK")
  write_dispatch_config "$home/config" medium
  printf 'brief for the effort ladder case\n' > "$TMP_ROOT/dispatch-brief.md"

  out=$(PATH="$(dirname "$fake"):$PATH" FM_OMP_BIN="$fake" \
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_PROJECTS_OVERRIDE="$home/projects" \
    TYPESAFE_API_KEY=fixture "$DISPATCH" "$TMP_ROOT/dispatch-brief.md" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "medium on a low|high|max model must not resolve silently: $out"
  assert_contains "$out" "malformed rules file" "the mismatch must refuse the configured rules: $out"
  assert_contains "$out" "each use profile effort must be supported by its harness and model" \
    "the refusal must name the effort axis as the problem: $out"

  # The supported pair still resolves: the gate rejects the mismatch, not omp.
  write_dispatch_config "$home/config" high
  out=$(PATH="$(dirname "$fake"):$PATH" FM_OMP_BIN="$fake" \
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_PROJECTS_OVERRIDE="$home/projects" \
    TYPESAFE_API_KEY=fixture "$DISPATCH" "$TMP_ROOT/dispatch-brief.md" 2>&1)
  status=$?
  expect_code 0 "$status" "a supported model/effort pair must still resolve: $out"

  pass "config: a level the model does not advertise is refused, a supported one still resolves"
}

# --- the spawn ---------------------------------------------------------------

# Replace the stock logging fake tmux with one that ALSO runs the staged launch,
# emulating a live pane. The stock fake only records send-keys, so fm-spawn's
# post-launch readiness gate (which waits for the omp extension's agent_start
# busy event) could never settle and every spawn would fail after its bound. This
# variant keeps the stock logging shape and additionally executes the expanded
# launch line in the background, so the fixture omp emits the busy event exactly
# as the real extension does.
write_pane_tmux() {  # <fakebin> <launch-log>
  local fakebin=$1 launchlog=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  capture-pane) exit 0 ;;
  send-keys)
    payload='' skip=''
    for a in "\$@"; do
      if [ "\$skip" = 1 ]; then skip=; continue; fi
      case "\$a" in
        -t) skip=1; continue ;;
        -l | Enter | C-m) continue ;;
      esac
      payload=\$a
    done
    # fm-spawn types the launch as a short source line (". '<path>'") whose
    # target file carries the real command; expand it so the log records what
    # the pane actually ran, which is the record every launch assertion reads.
    case "\$payload" in
      ". '"*"'")
        staged=\$(printf '%s' "\${payload:3}" | tr -d "'")
        [ -f "\$staged" ] && payload=\$(cat "\$staged")
        ;;
    esac
    # Only bare pane-setup lines are dropped: fm-spawn types `treehouse get`,
    # `cd`, and single `export VAR=value` lines before the real launch.
    run=1
    case "\$payload" in
      '' | treehouse\ * | cd\ *) run='' ;;
      export\ *)
        case "\$payload" in *';'*) ;; *) run='' ;; esac
        ;;
    esac
    [ -n "\$run" ] || exit 0
    printf '%s\n' "\$payload" >> "$launchlog"
    # Stand in for the live pane WITHOUT executing the launch: the command names
    # the task's per-task omp extension through -e, so the agent_start busy event
    # the post-launch readiness gate waits for is synthesized from that path.
    # Executing the real command would run the vendor binary and the pane's
    # `treehouse get` against the developer's own pool, which a test must not do.
    ext=\$(printf '%s' "\$payload" | tr -d "'" | tr ' ' '\\n' | grep -m1 'omp-ext\\.ts\$')
    if [ -n "\$ext" ]; then
      state=\${ext%/*}; base=\${ext##*/}; id=\${base%.omp-ext.ts}
      gen=''
      [ -f "\$state/\$id.busy-gen" ] && gen=\$(cat "\$state/\$id.busy-gen")
      printf 'v1 gen=%s seq=2 state=busy source=omp-ext event=agent_start ts=%s\\n' \\
        "\$gen" "\$(date +%s)" > "\$state/\$id.busy-state" 2>/dev/null
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}
make_ladder_spawn_case() {  # <name> <id> <catalog-json>
  local name=$1 id=$2 catalog=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  # fm-spawn's pane line runs `treehouse get` before the launch; this fixture
  # never executes that setup step (see write_pane_tmux), so the stock no-op stub
  # is all that is needed to keep a real pool worktree from being provisioned.
  write_fake_omp "$fakebin" "$catalog" >/dev/null
  write_pane_tmux "$fakebin" "$case_dir/launch.log"
  fm_test_spawn_home "$home" omp
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

test_spawn_surfaces_the_mismatch_and_records_what_shipped() {
  local rec id=omp-ladder-bad-q1 out status launch meta
  rec=$(make_ladder_spawn_case mismatch "$id" "$CATALOG_DEEPSEEK")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$rec
EOF

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --harness omp --model vibeproxy/deepseek-v4.1-flash --effort medium --scout 2>&1)
  status=$?
  expect_code 0 "$status" "an unsupported level must surface, not refuse the launch: $out"
  assert_contains "$out" "warning: requested effort 'medium' is not in model 'vibeproxy/deepseek-v4.1-flash'" \
    "the mismatch must be LOUD on the spawn output: $out"

  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--thinking 'medium'" "a level the model cannot honour must not reach the launch line"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep "effort=medium" "$meta" "the record must keep the requested level for traceability"
  assert_grep "effort_applied=" "$meta" "the record must state the level that actually shipped"

  pass "spawn: a model/effort mismatch is surfaced and omitted, never silently launched"
}

test_spawn_supported_pair_launches_unchanged() {
  local rec id=omp-ladder-ok-q2 out status launch meta
  rec=$(make_ladder_spawn_case supported "$id" "$CATALOG_DEEPSEEK")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$rec
EOF

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --harness omp --model vibeproxy/deepseek-v4.1-flash --effort high --scout 2>&1)
  status=$?
  expect_code 0 "$status" "a supported model/effort pair must still launch: $out"
  assert_not_contains "$out" "is not in model" "a supported level must produce no mismatch warning: $out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--thinking 'high'" "the supported level must reach the launch line"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep "effort=high" "$meta" "the record must carry the pinned level"
  assert_no_grep "effort_applied=" "$meta" "a level that shipped as requested needs no applied marker"

  pass "spawn: a supported model/effort pair launches unchanged"
}

test_spawn_unreadable_ladder_launches_with_notice() {
  local rec id=omp-ladder-unreadable-q3 out status launch meta
  # An empty listing is the observed post-upgrade shape and must establish
  # nothing: the launch proceeds and the record is not marked as downgraded.
  rec=$(make_ladder_spawn_case unreadable "$id" '{"models":[]}')
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$rec
EOF

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --harness omp --model vibeproxy/deepseek-v4.1-flash --effort medium --scout 2>&1)
  status=$?
  expect_code 0 "$status" "an unreadable ladder must not refuse the launch: $out"
  assert_not_contains "$out" "is not in model" "an unreadable ladder must not claim a mismatch: $out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--thinking 'medium'" "an unreadable ladder must leave the requested level in force"

  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "effort_applied=" "$meta" "an unreadable ladder must not mark the level as downgraded"

  pass "spawn: an unreadable ladder proceeds with a notice and no downgrade"
}

test_spawn_ultra_contract_unchanged() {
  local rec id=omp-ladder-ultra-q4 out status launch
  rec=$(make_ladder_spawn_case ultra "$id" "$CATALOG_DEEPSEEK")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$rec
EOF

  # omp can never carry ultra, and that refusal predates this change.
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --harness omp --model vibeproxy/deepseek-v4.1-flash --effort ultra --scout 2>&1)
  status=$?
  expect_code 1 "$status" "ultra on omp must still refuse: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused ultra spawn must publish no record"

  pass "spawn: the ultra native contract still refuses outside pi/pi-signed"
}

# --- run ---------------------------------------------------------------------

test_owner_narrows_harness_set_by_model_ladder
test_owner_never_refuses_on_unreadable_or_absent_ladder
test_owner_preserves_ultra_contract
test_dispatch_config_rejects_the_observed_mismatch
test_spawn_surfaces_the_mismatch_and_records_what_shipped
test_spawn_supported_pair_launches_unchanged
test_spawn_unreadable_ladder_launches_with_notice
test_spawn_ultra_contract_unchanged
