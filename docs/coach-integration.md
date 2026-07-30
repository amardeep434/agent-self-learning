# AI Engineering Coach integration (optional)

Three independent, off-by-default integrations with
[microsoft/AI-Engineering-Coach](https://github.com/microsoft/AI-Engineering-Coach) (MIT).
Enable them in the resolved store's `self-learning.conf` — see "Where everything lives" in
the [README](../README.md).

| Flag | Route | What it does | Requires |
|------|-------|--------------|----------|
| `SL_COACH_RULES_ENABLED=true` | **A — rules** | Evaluates Coach's anti-pattern rules (vendored in `vendor/coach-rules/`) against our own session index and the harnesses' telemetry; triggered rules steer the background review. Fully automatic. | nothing extra |
| `SL_COACH_EXPORT_ENABLED=true` | **B — export** | Reads Coach's *complete* analysis from `~/.aiec/summary-latest.json`, written by our maintained fork's auto-export patch. Richer than Route A. | the fork's `.vsix` installed in VS Code |
| `SL_SKILLOPT_ENABLED=true` | **C — SkillOpt** | Manual wrapper around microsoft/SkillOpt's Sleep CLI. Wired into nothing. | a SkillOpt checkout or the `skillopt-sleep` CLI |

When A and B are both enabled, signals are merged and deduplicated by rule id; **Route B
wins**, because it comes from Coach's complete analyzer rather than our narrower re-derivation.

Signals reach the reviewer prompt via `coach-signals.py`, which `session-review.sh` and
`copilot-session-review.sh` call and then append as a "Coach signals" section when the
output is present and less than 7 days old. `tests/test-session-review.sh` carries a
"coach signal id reaches prompt" assertion that fails if that wiring regresses.

---

## Route A — rules mode

**44 of the 45 vendored rules are evaluated.** Re-derive rather than trusting that number:

```bash
python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("cre", "scripts/coach-rules-eval.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rules = {p.stem for p in pathlib.Path('vendor/coach-rules').glob('*.md') if p.name != 'UPSTREAM.md'}
print(len(rules), "vendored;", len(rules) - len(m.UNSUPPORTED_REASONS), "evaluated")
PY
```

`tests/test-coach-rules-eval.py` pins the partition (`EXPECTED_EVALUATED`,
`EXPECTED_TELEMETRY_ADAPTERS`, `EXPECTED_TOTAL_RULES`), so a silent coverage drop fails
the suite. `TelemetryAbsentSkipsLoudlyTest` separately pins that a *missing* harness store
produces loud skips rather than a false all-clear.

### These are ADAPTATIONS, not re-implementations

Route A's `detect` parser is a deliberately narrow subset of upstream's DSL (upstream ships
a ~4,300-line lexer/parser/interpreter under `src/core/dsl/`). Each adapter pins the exact
predicate it implements with `_pin()` and **refuses to run if a re-vendor changes it**.
Re-vendor with `bash scripts/sync-coach-rules.sh`; the current pin is recorded in
`vendor/coach-rules/UPSTREAM.md`.

### The two data sources

1. **The project's own index** (`SL_SEARCH_DB`) — per-message role/content/timestamp.
   Feeds **11** rules, each narrowing "requests" scope to per-user-message text/timestamp
   and documenting its own limitation (grouping by `project_path` instead of
   `workspaceName` for `tunnel-vision`; regex-counting `"[tool: X]"` markers instead of
   structured `toolsUsed[]` for `mcp-tool-bloat`, which loses arguments and paths).
2. **`scripts/lib/telemetry.py`** — the harnesses' own stores, read-only: Copilot's
   `events.jsonl` and `session-store.db` (`assistant_usage_events`), its per-session
   `workspace.yaml`, and Claude Code's transcripts. Feeds the other **33**.

`vendor/coach-rules/tables/` holds three artefacts vendored the same way the rule files
are and pinned by SHA-256 in `scripts/lib/coachtables.py`: upstream's `MODEL_TIERS` and
`WORK_TYPE_PATTERNS` (verbatim TypeScript slices, extracted with a loud failure if the
anchor is missing) and the `leo-profanity` 1.9.0 dictionary upstream itself depends on,
stored as SHA-256 hashes rather than plaintext. Hashing is behaviour-preserving because
`leoProfanity.check()` is exact whole-word set membership, and it keeps this repository
free of the wordlist — the property Microsoft wanted when they pushed the list into an
external package. A table that changes stops the adapters that read it until a human
updates the pin, and the mechanism is tested by executing the mutation rather than
asserting it.

### The one rule still skipped

- **`no-devcontainer` — unreachable while no VS Code session source is plumbed into
  `telemetry.py`.** Not because of `requiresIdeContext`: because upstream's own
  `computeDevcontainerStats` opens with
  `sessions.filter(s => VSCODE_HARNESSES.has(...))` (`src/core/dsl/interpreter.ts:579-585`),
  so for a CLI harness the scored population is empty **inside upstream's own function**,
  by a hardcoded gate, before any field of ours is consulted.

  > **Corrected 2026-07-30.** This bullet said "genuinely unreachable" and called itself
  > the only entry in the table for which that was true. That asserted a *structural*
  > impossibility, and it is not one. Plain VS Code is labelled `'Local Agent'`
  > (`src/core/parser-vscode.ts:18-26`), which **is** a member of `VSCODE_HARNESSES` — and
  > this project ships VS Code Copilot Chat as a declared peer harness. The rule is
  > unreachable because our telemetry emits no harness field and reads no VS Code source
  > at all, not because no supported harness can satisfy the gate:
  >
  > ```bash
  > grep -n '"harness"' scripts/lib/telemetry.py scripts/coach-rules-eval.py   # zero hits
  > grep -n "_vscode_" scripts/lib/telemetry.py                                # no reader
  > ls ~/.config/Code/User/workspaceStorage/*/chatSessions 2>/dev/null | head  # data exists
  > ```
  >
  > This is the same shape as the "First correction" below — *"The telemetry was unplumbed
  > here, not unobtainable."* Reaching the gate would additionally require requests
  > carrying `toolConfirmations[].isTerminal`, which is **unverified** for VS Code's
  > `chatSessions` JSON. So "obtainable" means the gate becomes passable, not that the rule
  > is proven to fire.

Its skip reason is user-visible output, and `tests/test-coach-rules-eval.py` enforces that
a reason with no checkable evidence — an upstream `file:line` or a measurement over the
local stores — fails the suite.

### Coverage history, recorded because it is a failure mode

This section said **11** rules until 2026-07-26, then **24**, then **42**, and now **44**.
Every correction went the same direction.

- **First correction.** Upstream is not a VS Code-internals consumer — its own README is
  *"any harness, one dashboard"*, `src/core/parser-vscode-cli.ts` parses Copilot CLI's
  `~/.copilot/session-state/<id>/events.jsonl`, and `src/core/parser-claude.ts` parses
  Claude Code's `~/.claude/projects/*.jsonl`. Those are the files this project already
  reads. The telemetry was **unplumbed here, not unobtainable**.
- **Second correction.** An adversarial re-analysis of the 21 surviving skips found that
  **twelve of the twenty-one skip messages asserted something false about upstream's
  source or the local data — and every one of the twelve pointed away from doing work.**
  A random error rate would have created work about half the time.
- **Third correction (2026-07-28, commit `cddd149`).** `broken-flow-state` and
  `no-file-context` were implemented, taking 42 → 44.

Two arguments did most of the damage and are now **banned** in the skip table's header
(`UNSUPPORTED_REASONS`, `scripts/coach-rules-eval.py`):

- *"`requiresIdeContext: true` proves the rule is unreachable."* It does not. Upstream
  computes `skipIdeDetectors` only when a harness FILTER is applied to the dashboard
  (`src/core/analyzer-patterns.ts:262`); in the default view all 45 detectors run over a
  corpus that includes CLI sessions. The flag is about attributing a finding in a
  mixed-harness view, not about the input being absent.
- *"A conjunct that is constant here makes the rule a constant."* A universally-true
  clause inside a conjunction is a NO-OP; the discriminating work is done by the other
  clauses. Three rules were skipped on this.

### Adaptations are declared, not glossed

Where a CLI mapping differs from upstream's field, the adapter says so and says what
differs: the Claude `CLAUDE.md`-for-`copilot-instructions.md` substitution;
`approved-for-location` as Copilot's analogue of `autoApproveScope: 'always'` (Copilot has
no session-scoped approval, so upstream's `'session'` arm is dead here, and Claude Code
records no confirmations at all); `ExitPlanMode` as Claude Code's plan-mode marker,
because `permissionMode` never carries the value `plan` even in sessions that plainly used
it; and per-request `customInstructions` redefined as "this workspace has an instruction
file", which loses upstream's ability to tell two requests in one workspace apart.

### Three rules ship with replaced remediation text

`no-slash-commands`, `agent-mode-for-asks` and `no-file-context` are genuine findings, but
upstream's "How to Improve" names `/fix`, `/explain`, `/tests`, `/doc`, an Ask/Chat mode,
`#file` and "the editor" — none of which exist in either CLI. That text is what gets
written into the user's memory file. Skipping would discard a finding to avoid a text
problem; emitting it would persist bad advice. `SUGGESTION_OVERRIDES` in
`coach-rules-eval.py` substitutes CLI-accurate text, marked `ADAPTED FOR CLI`, with the
rule id and count still upstream's. The overrides are capped at
`OVERRIDE_MAX_CHARS = 240` because `coach-signals.py` sanitizes every suggestion to that
length — the first version of them was cut mid-word, losing the half that said what to do
instead.

### One thing measured, working, and deliberately not shipped

Defining auto-approval by subtracting permission events from tool executions (1046 `bash`
executions against 219 `shell` permission requests) puts `yolo-mode` at ~0.96 and fires it
loudly. Rejected under upstream's rule id because Copilot CLI has an unpublished built-in
allow-list of safe read-only commands, so "no permission event" conflates "the user
auto-approved this" with "Copilot never asks about `ls`".

### The standing rule

No rule is enabled unless it is shown firing on a fixture built from real event shapes,
and every rule keeps a fire/no-fire test **pair**. A rule that evaluates but can never
fire hides a gap instead of reporting it, which is worse than a loud skip — and the
inverse, shipping dead rules to raise a number, is the failure this section's own history
warns about.

---

## Route B — export mode

`~/.aiec/summary-latest.json` does not appear on its own. Upstream Coach ships only
`aiEngineerCoach.exportSummary`, which opens a save dialog and so cannot be driven
unattended. **Our fork adds a dialog-free variant plus an auto-export after every data
reload** — [`amardeep434/AI-Engineering-Coach`](https://github.com/amardeep434/AI-Engineering-Coach),
branch `feature/auto-export`, `src/summary-export-auto.ts`.

With the fork's `.vsix` installed in VS Code:

1. Open the Command Palette (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd>, or
   <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd> on macOS).
2. Run **`AI Engineer Coach: Export Summary (Auto, No Dialog)`** (command id
   `aiEngineerCoach.exportSummaryAuto`). No dialog should appear; a status-bar message
   names the file it wrote. Running **`AI Engineer Coach: Reload Data`** triggers the same
   export, which is what makes the route self-maintaining once set up.
3. Confirm it landed, then set `SL_COACH_EXPORT_ENABLED=true`:

   ```bash
   jq '.antiPatterns.totalOccurrences' ~/.aiec/summary-latest.json
   ```

If the command is missing from the palette, the installed extension is upstream's build
rather than the fork's.

**Live status.** Route B produced its first real payload on **2026-07-28**: the fork's
`.vsix` was installed and the export run for the first time on any machine, yielding 10
signals with `source=export` and counts matching the export exactly. A real export carries
eight top-level keys (`activity`, `antiPatterns`, `filter`, `flow`, `generatedAt`,
`production`, `schemaVersion`, `totals`); before that run, Route B had only ever been
tested against an invented minimal shape. `tests/fixtures/coach-export-v1.json` now pins
the real top-level shape, normalised (dates fixed to 2020, all counts scaled by ten
including the numbers embedded in upstream's generated prose, so it stays arithmetically
self-consistent) and guarded by a standing privacy scan in `tests/test-coach-export-read.py`.

That run also exposed a silent-zero defect, now fixed: the reader returned `[]` and exit 0
for **both** "file missing" and "file unparseable", so a corrupt export was
indistinguishable from "Coach is not installed". Now an absent export stays `[]` + exit 0
while a present-but-unreadable one exits 1 naming the path and exception type.

**Fork sync state.** Do not trust a number written here; re-derive it:

```bash
gh api repos/amardeep434/AI-Engineering-Coach/compare/microsoft:main...amardeep434:feature/auto-export \
  --jq '{ahead: .ahead_by, behind: .behind_by}'
```

Observed 2026-07-29: `{"ahead": 2, "behind": 0}`. See the fork's `FORK-NOTES.md` for the
sync protocol and `scripts/sync-upstream.sh` for the rebase-and-rebuild run.

---

## Route C — SkillOpt (manual, and wired into nothing)

`scripts/skillopt-run.sh` is a thin opt-in wrapper around
[microsoft/SkillOpt](https://github.com/microsoft/SkillOpt)'s Sleep CLI. It is installed
into the store's `scripts/` directory, but **no hook, cron job or curator step invokes
it** — you run it yourself:

```bash
SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO=/path/to/SkillOpt \
  <store>/scripts/skillopt-run.sh status    # or harvest | dry-run | adopt
```

It resolves SkillOpt in upstream's own precedence order: a source checkout
(`$SL_SKILLOPT_REPO/plugins/run-sleep.sh`) first, then a `skillopt-sleep` on `PATH`
(`pip install skillopt`). With neither, it explains which one is missing and exits 0. The
expensive `run` verb additionally requires `SL_SKILLOPT_RUN_CONFIRMED=true`.

**Nothing reads SkillOpt's output back into this system.** Importing a resulting
`best_skill.md` into the skill store, with provenance, and any automatic scheduling are
both deferred.

Status as of 2026-07-28: `status`, `harvest` and `dry-run` have been exercised end to end
against a real checkout on upstream's default `mock` backend at zero cost. The `run` verb
has **never** been executed on any backend, and SkillOpt has never harvested a non-empty
session store, so the data contract between it and our store is still unproven.
