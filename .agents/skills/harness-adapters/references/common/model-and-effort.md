# Model and effort

Load this with the selected tool reference before choosing, validating, or changing either axis.
Add `references/common/dispatch.md` for configured profile precedence.

## Axes and precedence

`../../../bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values selected at intake; scripts never parse natural-language dispatch rules.
The tool reference records verified flags, accepted values, omission behavior, and discovery.

Effort precedence is a per-task captain instruction, then applicable dispatch profile or secondmate pin, then the fallback below.
Never replace either higher-precedence value.
Use the fallback only when neither specifies effort.

Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels as complexity, uncertainty, blast radius, or open-ended reasoning rises.
If an adapter lacks `xhigh`, cap at its highest supported non-`max` level rather than silently omitting the intent.
Never select `max` through this fallback; only an explicit per-task or standing captain preference permits it.

The explicit native `ultra` value follows the model-scoped refusal contract in `../../../bin/fm-harness.sh validate-native-effort`; it is never silently omitted or mapped to a Pi level.
For other values, if requested effort is outside the adapter's accepted set, the spawn records `effort=` in task metadata but emits no effort flag.
This preserves launch success instead of passing a known-bad value.
A harness with no verified interactive effort flag follows the same record-and-omit contract.

The accepted set is also narrowed by the MODEL's own advertised thinking ladder, because a harness-level set alone overstates what a given model can honour: a standing config that asks for `medium` on a model advertising only `low|high|max` passes a harness-level check, is recorded as `effort=medium`, and launches with no signal that the level could not run.
`bin/fm-harness.sh effort-verdict` (and `effort-verdicts` for whole configs) is the single owner of that lookup, so no caller restates a ladder; `bin/fm-spawn.sh` asks it before emitting any effort flag and `bin/fm-dispatch-resolve.sh` and `bin/fm-bootstrap.sh` ask it when validating `config/crew-dispatch.json`.
When the model's ladder omits a requested level the spawn reports it LOUDLY and omits the flag, and the task record keeps `effort=` (the request) beside `effort_applied=` (what actually shipped, empty when no flag was emitted) so the record can never silently overstate the request.
An unreadable, undeclared, or unlisted ladder establishes nothing: it stays a notice and never refuses a launch, and a provider the listing does not know (extension-registered providers are never listed) passes through exactly as before.

## Harness and provider identity

Harness identity is independent of model provider.
`harness=pi` with `model=xai/grok-*` is Pi using xAI, not standalone Grok Build, and does not require Grok CLI login.
`harness=cursor` with `model=cursor-grok-4.5-*` is Cursor routing a Grok model, not `harness=grok`.

No script resolves credential provenance for you.
Establish it from the tool's discovery surface and `quota-axi auth --json` per-provider sources, and show the reasoning rather than inferring it from a name.

## Discovery

Treat model and provider knowledge as current discovery, not a permanent namespace or mapping.
Use the selected tool reference's authoritative surface in the current authenticated environment because availability changes by version, account, and configuration.

For an unfamiliar namespace, establish support and provider identity from that harness's CLI help, model listing, or current documentation.
An account-reaching listing that omits a model is concrete unsupported evidence; block the candidate and quote it.
An unreachable surface establishes nothing; report uncertainty instead of a verdict.

For a matched profile array, return to `quota-array-dispatch` only after establishing every candidate's harness support, provider relationship, and uncertainty.
