# Fork-sync live validation summary

Branch merge: `eb0e8e4` (parents `8a83f36` + `888871d`).
Intent: preserve fork behaviours while adopting upstream Calm shared preservation and fixes through `888871de`.

## Scenarios driven

1. **Project integration base spawn** — `./bin/fm-test-run.sh tests/fm-spawn-pool-base-freshen.test.sh`
   - pass: `ok - a recorded integration base refreshes the pooled worktree from its fetched remote tip`
   - adversarial refusals for local-only / missing / dirty bases also passed
   - log: `01-integration-base.log`

2. **Automatic terminal teardown** — `./bin/fm-test-run.sh tests/fm-inactive-reconcile.test.sh`
   - pass: repeated `automatic teardown: task=... complete` and `all inactive reconciliation tests passed`
   - includes refusal/incarnation guards
   - log: `02-automatic-teardown.log`

3. **Dead-window watcher retirement** — `bash tests/fm-watch-triage.test.sh --watch-record-sweep`
   - pass: retires dead-window records, preserves live keys, bounded/idempotent, proven-absence only
   - log: `03-dead-window-retire.log`

4. **Worker reporting boundary** — `./bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh`
   - pass: `ok - fm-spawn: actual ship/scout launch commands deliver the worker role contract`
   - suite asserts `report all outcomes and blockers to firstmate, never directly to the captain`
   - log: `04-worker-reporting.log`

5. **Crew-state authoritative run selection (adopted upstream)** — `./bin/fm-test-run.sh tests/fm-crew-state.test.sh`
   - pass: live-sibling / replacement-gate / competing-run ambiguity cases; `all fm-crew-state tests passed`
   - log: `05-crew-state-run-selection.log`

6. **Calm shared mid-turn preservation (adopted upstream)**
   - Direct Node exercise of shared `calmTextIsSubstantive` / 240-char-or-newline rule via the Pi symlink and Claude mod (same inode): `06b-calm-preservation-unit.log` — all checks ok
   - `tests/fm-calm-claude-mod.test.sh` could not run under host `/bin/bash` 3.2 (`${var@Q}` bad substitution); suite already uses that construct on upstream `888871d`
   - Pi renderer E2E gated skip: `@earendil-works/pi-coding-agent` not installed; log `06-calm-preservation.log`

## Verdict inputs

Fork-preserved product surfaces all passed live. Adopted Calm preservation policy proven via shared module execution. Pi interactive Calm E2E remains environment-gated.
