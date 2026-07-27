# Skip re-analysis audit — the 21 unevaluated Coach rules, and what is actually left

Date: 2026-07-26
Branch: `harness-neutral-persistence` @ `3a3eec2`
Mode: **read-only analysis. Nothing was implemented.** No paid model call was made.

Evidence base, all re-derived in this session rather than quoted from this repo's reports:

- `microsoft/AI-Engineering-Coach` cloned fresh at HEAD `766d0f2` (`git log` confirms it is the
  commit `vendor/coach-rules/UPSTREAM.md` records). Every upstream claim below cites a file and
  line I read in that clone.
- The user's live stores, read never written: `~/.copilot/session-state/*/events.jsonl`
  (62 sessions), `~/.copilot/permissions-config.json`, `~/.claude/projects/**/*.jsonl`
  (718 transcripts), `~/.claude/settings.json`.
- The tree: `scripts/coach-rules-eval.py` (`UNSUPPORTED_REASONS`, 21 entries),
  `scripts/lib/telemetry.py`, `vendor/coach-rules/*.md` (45 rules, 24 evaluated).

CI at exactly this HEAD: run `30185809939`, **all six cells green** (verified with `gh run view`,
`headSha` matches `git rev-parse HEAD`).

---

## Verdict up front

| Verdict | Count |
|---|---|
| genuinely unreachable | **1** |
| implementable, we rationalized | **12** |
| implementable with stated cost | **8** |

**Twelve of the twenty-one skip messages contain a statement about upstream's code or about the
data on this machine that is simply false**, and in every one of the twelve the falsehood points
away from doing work. That is the answer to the question that commissioned this round. It is not
universal — `broken-flow-state` and `no-devcontainer` are stated honestly — but it is a pattern,
not an accident.

The recurring shapes of the error are worth naming, because they will recur:

1. **"A constant-true clause makes the rule a constant."** Used for `no-spec-structure`,
   `agentic-no-tools`, `agent-mode-for-asks`. It is a logic error. A clause that is universally
   true inside a conjunction is a *no-op*; the discriminating work is done by the other clauses,
   which are all live. `no-spec-structure`'s skip message literally says "the rule is a constant"
   about a predicate whose other five sub-clauses are regex tests on the user's first message.
2. **"We would have to invent the table."** Used for `profanity`, `session-drift`,
   `premium-waste`, `premium-for-lookup-questions`, `auto-avoidance`. Every one of those tables
   exists upstream, in source, ~25 lines each, MIT-licensed, and vendorable by exactly the
   mechanism already built for the rules.
3. **"The measurement has a zero numerator."** Used for `yolo-mode` and `auto-approve-terminal`.
   The numerator is 7, not 0, corpus-wide.
4. **"Upstream reads this from the IDE."** Used for `instruction-bloat`. Upstream reads it from
   the CLI session's own `workspace.yaml`, in a function whose signature takes `isCLI` as a
   parameter.

---

## Part 0 — the framing that has to be corrected first

**Coach rule coverage is not owed under the plan this branch is named after.** The Coach
integration comes from `docs/superpowers/plans/2026-07-22-copilot-port-and-coach-integration.md`.
Nothing in `2026-07-25-harness-neutral-persistence.md` mentions Coach, the 45 rules, or a
coverage target. Everything in Parts 1 and 2 below is therefore **discovered work, not debt** —
which makes it *more* important to describe honestly, not less, because there is no contract
forcing a correction and the only thing keeping the numbers true is the skip messages themselves.

The standing principle — *a rule that evaluates but can never fire because its input is
structurally always empty is worse than a loud skip* — is correct and I am not weakening it. What
the audit found is that it was invoked for inputs that are **unplumbed**, not structurally empty,
eleven times out of twelve where it was invoked at all. The one place it genuinely applies
(`no-devcontainer`) is the one place the skip message under-explains why.

---

## Part 1 — why the rules exist, and what upstream really requires

### Upstream is a CLI consumer. Confirmed, and stronger than previously recorded.

`src/core/parser-harnesses.ts` registers Claude Code, Codex CLI and OpenCode collectors;
`src/core/parser-vscode-cli.ts` (457 lines) parses Copilot CLI's own
`session-state/<id>/events.jsonl` — byte-for-byte the file `scripts/lib/telemetry.py` reads.
`src/core/types/session-types.ts:88-91` documents Copilot CLI as a field origin by name.

### The `requiresIdeContext` flag: what it actually gates

Exactly eleven vendored rule files carry `requiresIdeContext: true` — verified by grep over
`vendor/coach-rules/*.md`, and the set matches the eleven this project calls "IDE-only".
`src/core/rule-engine.ts:281` and `src/core/detector-registry.ts:270` drop them when
`skipIdeDetectors` is set.

But read how `skipIdeDetectors` is computed (`src/core/analyzer-patterns.ts:262`):

```ts
const skipIdeDetectors = !!(f?.harness && !f.harness.startsWith('Local Agent') && f.harness !== 'Xcode');
```

Two things follow that the prior reports did not record:

1. `'Local Agent'` **is** upstream's label for VS Code (`src/core/parser-vscode.ts:25` returns it
   for a plain VS Code logs dir). So the flag does drop those eleven for `'GitHub Copilot CLI'`
   and `'Claude Code'`. The prior conclusion holds.
2. It only drops them **when a harness filter is applied**. In upstream's default unfiltered
   dashboard, all 45 detectors run over a corpus that includes CLI sessions. So upstream does not
   treat these rules as meaningless for CLI data; it treats them as *not attributable* to a CLI
   harness in a filtered view. That is a presentation decision about a mixed-harness dashboard,
   not a statement that the data is absent.

**This is the crux.** The prior rounds adopted `requiresIdeContext` as a proof of unreachability.
It is not one. It is upstream's answer to a question this project does not ask. Whether each of
the eleven is reachable *here* has to be decided rule by rule from the data — which is what
follows.

### Rule-by-rule: purpose, real requirement, upstream's own reason

The table gives, for each rule, what upstream needs in code (file:line), what is on disk here,
and whether upstream skips it for absence or for lack of investment.

| Rule | Upstream's actual requirement | Present here? | Upstream skips because |
|---|---|---|---|
| `agent-mode-for-asks` | `agentMode` + 5 live clauses (`interpreter.ts` generic path) | 5 of 6 clauses captured | no CLI ask-mode **to recommend** — a remediation problem, not a data one |
| `agentic-no-tools` | `agentMode` OR `agentName`, `toolsUsed` | both captured | same |
| `auto-approve-terminal` | `computeAutoApproveStats`, `interpreter.ts:815` — counts confirmations with `autoApproveScope ∈ {session, always}` | see below — **7 real events** | `toolConfirmations` populated only by `parser-vscode-request.ts`: **not invested**, not absent |
| `yolo-mode` | `computeYoloStats`, `interpreter.ts:658` — identical scope test | same | same |
| `instruction-bloat` | `resolveCustomInstructionsBytes(entryPath, isCLI)`, `parser-vscode.ts:118` | **`workspace.yaml` exists in every Copilot session dir** | **it does not skip it** — it computes it for CLI |
| `no-custom-instructions` | per-request `customInstructions[]` — CLI parser never sets it | derivable, not present | not invested |
| `no-devcontainer` | `computeDevcontainerStats`, `interpreter.ts:581` — **hard-filters `VSCODE_HARNESSES`** and needs `session.hasDevcontainer` | population empty by construction | **genuinely absent** |
| `no-file-context` | `referencedFiles`/`editedFiles` meaning *chat-attached* context | Copilot `user.message.attachments` is the true analogue | not invested |
| `no-plan-mode` | `hasPlanning`, `interpreter.ts:~1780` — `agentMode.includes('plan') OR slashCommand=='plan' OR messageText` | Claude Code records `permissionMode` per user message | not invested (upstream has no Claude plan-mode mapping) |
| `no-skills` | `skillsUsed.length == 0`, count == total | **already captured for both harnesses** | not invested |
| `no-slash-commands` | `slashCommand` — extracted only in the VS Code request parser | **133 real `<command-name>` in Claude corpus** | not invested |

---

## Part 2 — the specific suspicions, tested

### 2.1 `profanity` — the suspicion was right

Our skip: *"the wordlist is supplied by the rule and the vendored file carries none; upstream
keeps it in `src/core/profanity.ts`. Evaluating it would mean inventing a moderation wordlist — a
product judgment out of scope."*

`src/core/profanity.ts` is 46 lines and contains **no wordlist**. Its header says so explicitly:

> "Profanity detection backed by the `leo-profanity` dictionary, so the plaintext wordlist lives
> in an external package and is not committed to this repository."

`package.json:359` pins `"leo-profanity": "1.9.0"`. The npm registry metadata for that exact
version reports `license: MIT`, `description: "Profanity filter, based on Shutterstock
dictionary"`.

So: **we would not be inventing anything.** There is an MIT-licensed dictionary, pinned to a
version, that upstream itself uses. Vendoring it is the same act as vendoring the rules.

The reason that *should* have been written, and was not, is Microsoft's own: they deliberately
keep the plaintext list out of the repository. That is a real objection to a naive vendor — but
it has a cheap answer that was never considered. `leoProfanity.check()` is whole-word matching
after normalisation, so **storing SHA-256 hashes of the words instead of the words preserves
behaviour exactly** and commits no slurs. Upstream's `stripCode()` (strip fenced blocks and
inline backticks before checking) is 3 lines and must be ported with it, or every code snippet
containing a rude variable name becomes a false positive.

Verdict: **implementable, we rationalized.**
Cost: `sync-coach-rules.sh` gains a step that resolves `leo-profanity@<pinned>` from the registry
tarball and writes `vendor/coach-rules/tables/profanity-sha256.txt`; ~40 lines of adapter;
`stripCode` port; one `_pin()` on the version string. Under half a day.

### 2.2 The five "snapshot of an upstream table" rules — the suspicion was right, and the argument was self-refuting

Our skip: *"hardcoding a snapshot of it here would silently rot as models ship"* / *"implementing
it here would mean inventing a different one and calling it the same rule."*

Both tables are plain literals in upstream source:

- `MODEL_TIERS` — `src/core/dsl/interpreter.ts:267-284`, ~18 lines of `Record<string, number>`,
  plus `modelTierLookup()` at 286-292 (5 lines: strip `openai/|anthropic/|google/` prefix, strip a
  trailing `-YYYY-MM-DD`, lowercase, substring match, default 0). It is itself upstream's snapshot
  of GitHub's published multipliers — `src/core/constants.ts:9` cites
  `https://docs.github.com/en/copilot/concepts/billing/copilot-requests#model-multipliers`.
- `WORK_TYPE_PATTERNS` — `src/core/dsl/interpreter.ts:302-313`, ten `[RegExp, label]` pairs
  (`bug fix`, `refactor`, `test`, `documentation`, `devops`, `styling`, `configuration`,
  `performance`, `security`, `migration`), plus `classifyWorkText()` (first 300 chars, first
  match wins, default `'feature'`) and `workTypeCount()` at 1401.

The rot argument **proves too much and is already answered by this project's own machinery.** The
vendored rule files rot identically. The response was `sync-coach-rules.sh` plus a mutation-tested
`_pin()` that refuses to run an adapter whose rule text drifted. A table is not categorically
different from a predicate: both are upstream artefacts that change upstream, both are fetched by
the same script, both can be pinned by the same mechanism. Declining the table while shipping the
predicate is not a consistent position.

The one genuine asymmetry: rules are markdown fetched wholesale via the contents API, whereas the
tables are TypeScript object literals that must be extracted. That is a small real cost — a
brace-balanced slice keyed on `const MODEL_TIERS: Record<string, number> = {` that **fails loudly**
if the anchor is not found, rather than silently vendoring nothing. It is not a reason; it is a
line item.

Unlocks, given the tables:

- `premium-waste` — `modelTier` is the *only* missing input. `aiCode.length` landed with the
  `aiCode.loc` cluster; `modelId` and `messageLength` are captured.
- `premium-for-lookup-questions` — same, plus a question-opener regex that is **literal inside the
  vendored detect block**.
- `auto-avoidance` — same table, plus `countWhere(matched, "modelId", "matches", "(?i)auto")`,
  which is one regex over a captured field. `modelStats`/`topShare` already computed.
- `session-drift` — `workTypeCount` is the only missing input.

Verdict for all four: **implementable, we rationalized.**

### 2.3 The "IDE-only" eleven

#### 2.3.1 `agent-mode-for-asks` / `agentic-no-tools` — logic error

`agentic-no-tools` match: `(agentMode == "agent" OR agentName != "") AND toolsUsed.length == 0`,
`check: count > 10`. If `agentMode` is constant `"agent"`, the disjunction is a tautology and the
predicate reduces to **"turns that used no tools"** — a live, captured, discriminating count. The
rule is not dead; it is slightly broader than upstream's, and *correctly* so, because in a CLI
every turn genuinely is agent mode.

`agent-mode-for-asks` match has six conjuncts: `agentMode == "agent"` (tautology here) AND
`messageLength > 0` AND `messageLength < 80` AND `length(toolsUsed) == 0` AND `length(aiCode) == 0`
AND `length(referencedFiles) == 0` AND `length(editedFiles) == 0` AND `isCanceled == false`. Every
non-tautological conjunct is captured today. It evaluates.

There is also a fact the skip message asserts that is false. It says *"upstream's own CLI parser
hardcodes `agentMode='agent'` (parser-vscode-cli.ts, parser-claude.ts)"*. For `parser-claude.ts:607`
that is literally true. For `parser-vscode-cli.ts:210` it is **not**: the line reads
`str(ev.data?.agentMode) || 'agent'` — it reads the field from the event and falls back. Copilot
CLI simply does not emit it today; if it starts, upstream picks it up and we would not.

Claude Code's `permissionMode` is not an ask/agent toggle and I will not pretend it is —
`default`/`acceptEdits`/`dontAsk`/`auto` are permission postures, all of them agentic. So the
honest reason to skip these two is neither of the ones given: it is that **upstream's remediation
text has no CLI referent** — "Use Ask/Chat mode for quick questions" names a UI the user does not
have, and the suggestion string is what gets written into memory. That is a defensible product
call. It is not the call that was recorded.

Verdict, both: **implementable, we rationalized** (with a legitimate remediation objection that
should replace the current text if they stay skipped).

#### 2.3.2 `auto-approve-terminal` / `yolo-mode` — the measurement claim is false

Our skip: *"an AUTO-approved call emits no permission event at all … An auto-approve RATE computed
from this stream would have a permanently zero numerator: a rule that evaluates and can never
fire."* And, on the tempting mapping: *"`approved-for-location` … its 3.1s minimum shows it is a
human picking 'approve for this location'."*

Re-measured across all 62 sessions in `~/.copilot/session-state`:

| `permission.completed` `result.kind` | n |
|---|---|
| `approved` | 165 |
| `denied-no-approval-rule-and-could-not-request-from-user` | 150 |
| `denied-interactively-by-user` | 9 |
| **`approved-for-location`** | **7** |

**The numerator is 7, not 0.** And the reason given for discarding it does not survive contact
with upstream's own definition. `computeYoloStats` (`interpreter.ts:658-678`) counts a
confirmation as auto-approved when `autoApproveScope === 'session' || 'always'`. That scope is set
when the **user selects an auto-approve scope** — in VS Code that is a human clicking "Always
allow", which also takes human-scale time. Upstream never applies a latency test. Rejecting
`approved-for-location` because it took 3.1 seconds applies a criterion upstream does not use, to
reject the field that is upstream's exact semantic twin: an approval that is *persisted* rather
than one-shot. `~/.copilot/permissions-config.json` is where those 7 decisions landed — a
location-keyed `tool_approvals` allow-list, on disk, right now.

Under the faithful mapping the rules evaluate to "input live, ratio 7/331 = 0.021, below
threshold, silent." That is **the same status as `model-overreliance` and `cache-hit-starvation`,
which this project already ships**. There is no principle under which those two are acceptable and
these are not.

Separately, the user's subtraction hypothesis is also correct in principle and larger in effect.
`permission.requested` carries a `toolCallId`; `tool.execution_start` carries the tool call id.
The correlation is exact, not statistical:

| | corpus-wide |
|---|---|
| `tool.execution_start` with `toolName == "bash"` | **1046** |
| `permission.requested` with `kind == "shell"` | **219** |

827 shell executions ran with no permission event. In the single largest session, 706 bash calls
against 30 shell prompts. Under a subtraction definition `yolo-mode`'s ratio is ~0.96 and it
**fires loudly**.

I do *not* recommend shipping subtraction under upstream's rule id, and here the project's own
principle genuinely bites: Copilot CLI has an unpublished built-in allow-list of safe read-only
commands, so "no permission event" conflates "the user auto-approved this" with "Copilot never
asks about `ls`". That inflates the numerator with something the rule is not about. Subtraction is
a good *local* signal under a local name; it is not upstream's `yolo-mode`.

Verdict, both: **implementable with stated cost.** The faithful mapping
(`approved-for-location` → `autoApproveScope: 'always'`, denominator = all `permission.completed`)
is ~30 lines and correct. The sentence "a permanently zero numerator" must be struck from
`UNSUPPORTED_REASONS` whatever is decided, because it is false.

On Claude Code's settings, which the brief asked about: `~/.claude/settings.json` carries
`permissions.defaultMode: "default"` and a `deny` list, no `allow` list. So the *mode* is directly
knowable from config, but Claude Code's transcripts record no per-tool-call confirmation event at
all — there is nothing to correlate against. For Claude Code specifically these two rules are
**genuinely unreachable**; the Copilot half is what is implementable.

#### 2.3.3 `instruction-bloat` — the skip reason is factually wrong

Our skip: *"needs customInstructions byte size, which upstream reads from the VS Code workspace,
not from any CLI session log."*

`src/core/parser-vscode.ts:118`:

```ts
function resolveCustomInstructionsBytes(entryPath: string, isCLI: boolean): number | undefined {
  ...
  if (isCLI) {
    const wsYaml = path.join(entryPath, 'workspace.yaml');
    if (fs.existsSync(wsYaml)) folder = parseCLIWorkspaceFolderPath(wsYaml);
  } else { ... }
  const bytes = detectCustomInstructionsBytes(folder);
```

and `detectCustomInstructionsBytes` (line 106) is `fs.statSync(<folder>/.github/copilot-instructions.md).size`.
`parseCLIEventsFile` takes `customInstructionsBytes` as its fourth parameter
(`parser-vscode-cli.ts:398`). Upstream computes this **for CLI sessions**, from a file the CLI
itself writes.

And it is here: `~/.copilot/session-state/<id>/workspace.yaml` exists in every session directory I
checked. The Claude analogue is `<cwd>/CLAUDE.md`, and `cwd`/`gitRoot` is already extracted by
`telemetry.py` (lines 427-431 for Copilot, 757-759 for Claude).

Verdict: **implementable, we rationalized.** Cost: a YAML-folder-path read (one key, no YAML
parser needed), two `stat` calls, a session-scope adapter. Note the rule is `scope: sessions` and
threshold `maxBytes: 4000` — this repo's own `CLAUDE.md` is well over that, so it would fire, and
truthfully.

#### 2.3.4 `no-skills` — no argument was offered

Our skip: *"the rule fires on the ABSENCE of skill usage across an IDE session population, which a
CLI-only corpus cannot represent."* The detect block is `match: skillsUsed.length == 0`,
`check: count == total AND total > 50`. `skillsUsed` is captured for both harnesses (Copilot's
`skill` tool and `skill.invoked`; Claude's `Skill` tool) — the skip message says so itself, one
clause earlier. Nothing about "did you ever use a skill" is IDE-shaped. The sentence is a
restatement of the flag, not a reason.

Verdict: **implementable, we rationalized.** Cost: near zero — one adapter over an existing field.

#### 2.3.5 `no-slash-commands` — measured on the wrong harness

Our skip cites "0 of 136 real Copilot `user.message` events began with a slash." That measurement
is correct and I reproduce it. It was never extended to Claude Code, where slash commands are
recorded as `<command-name>` blocks inside user messages. Across all 718 transcripts:

`/model` ×53, `/plugin` ×21, `/usage-credits` ×8, `/effort` ×8, `/reload-plugins` ×7, `/login` ×7,
`/compact` ×7, `/exit` ×5, `/remote-env` ×4, `/usage` ×3, `/remote-control` ×3, `/clear` ×3,
`/config` ×2, `/doctor` ×1 — **133 real invocations.** The field is extractable with one regex.

Two honest caveats that belong in whatever replaces the current text: every one of those 133 is a
*built-in UI command*, not a task command, so the rule would fire for essentially everyone; and
the remediation ("Try /fix, /explain, /tests, /doc") names commands that do not exist in either
CLI.

Verdict: **implementable, we rationalized** (as a measurement). The remediation objection is real
and should be the recorded reason if it stays skipped.

#### 2.3.6 `no-plan-mode` — half wrong

Upstream's `hasPlanning` (`interpreter.ts:~1775`) matches on `agentMode.includes('plan')`,
`slashCommand == 'plan'`, or a `messageText` prefix. **Claude Code has a real plan mode**, and it
is recorded per user message. Across the corpus: `dontAsk` 3378, `auto` 884, `acceptEdits` 853,
`default` 369, `plan` 0 — plus one `ExitPlanMode` tool use, which is the tool Claude Code emits
when leaving plan mode. So the field carries the value the rule looks for, and on this corpus the
rule would fire — as a **true positive**, not a dead evaluation. `agentMode` is not constant for
Claude Code, and the skip message's blanket "neither CLI has that toggle" is wrong.

Copilot CLI has no plan mode; for that harness the rule is genuinely unreachable.

Verdict: **implementable, we rationalized** for the Claude Code half.

#### 2.3.7 `no-file-context` — right conclusion, wrong reason

Our skip: *"a CLI agent reads files by calling a tool, so the absence the rule looks for cannot
occur."* True of `referencedFiles` **as `telemetry.py` currently populates it** (from tool
arguments, mirroring upstream's CLI parser) — but that is a property of our plumbing, not of the
world. The rule means *context the human attached to the prompt*, and Copilot records exactly
that: `user.message.data.attachments`, an array of `{type: "file", path, displayName:
"@/abs/path", mentionIndex}` entries. In the largest session, 3 of 41 user messages carried
attachments — a 0.93 no-context rate against a 0.7 threshold. It would fire.

But implementing it means redefining `referencedFiles` away from upstream's semantics **for one
rule**, while four already-shipped adapters depend on the tool-argument definition. Answering
under upstream's rule id with a different input is precisely the drift the `_pin()` mechanism
exists to prevent.

Verdict: **implementable with stated cost** — and the cost is a rule-id decision, not engineering.
Ship it as a locally-named signal (`prompt-file-context`) with its own suggestion text, or not at
all. Do not ship it as `no-file-context`.

#### 2.3.8 `no-custom-instructions` — the inverted trap

Distinct from `instruction-bloat`. This one needs per-request `customInstructions[]`, which
upstream's CLI parser never populates. Evaluating it naively would give `usageRate == 0 < 0.05`
for every corpus — **a rule that always fires**, which is the same failure class as one that never
fires and arguably worse, since it looks like a finding. Making it meaningful requires defining a
CLI mapping (instruction file present for the session's workspace → non-empty), which is the
`instruction-bloat` plumbing reused.

Verdict: **implementable with stated cost**, strictly downstream of 2.3.3.

#### 2.3.9 `no-devcontainer` — the one genuine skip

`computeDevcontainerStats` (`interpreter.ts:581-610`) opens with
`sessions.filter(s => VSCODE_HARNESSES.has(asStr(s.harness)))` against
`VSCODE_HARNESSES = new Set(['VS Code', 'VS Code Insiders', 'Local Agent', 'Local Agent (Insiders)'])`
(`interpreter.ts:579`), then needs `session.hasDevcontainer` and `toolConfirmations[].isTerminal`.
For a CLI harness the filtered population is **empty by construction inside upstream's own
function** — this is a hard-coded harness gate, not an unplumbed field.

Verdict: **genuinely unreachable.** The current reason ("needs a vscode-vs-terminal request
classification") is vague; the real one is the `VSCODE_HARNESSES` filter, and it should be cited
by file and line.

### 2.4 The remaining reachable-but-unimplemented rules

Covered above: `session-drift`, `premium-waste`, `premium-for-lookup-questions`,
`auto-avoidance`, `profanity`. The rest:

#### `verbose-prompt-no-compression` — the reason is false; this is the cheapest win on the list

Our skip: *"the rule's pattern set is not carried in the vendored rule file."* It is. Both regexes
are **literals inside the vendored detect block** — the filler-word alternation
(`please|kindly|thanks|…`, required twice) and `hasSkillByPattern(allReqs,
"(?i)cavecrew|caveman|compress")`. There is no `patterns:` frontmatter because none is needed.
`messageLength`, `messageText` and `skillsUsed` are all captured.

Verdict: **implementable, we rationalized.** Cost: one adapter, ~25 lines, plus `hasSkillByPattern`
(`interpreter.ts:1224`, a 12-line loop). No vendoring, no table, no new field.

#### `no-spec-structure` — a misreading of the predicate

Our skip: *"the predicate is `someWhere(requests, agentMode, agent)`, and agentMode is hardcoded
'agent' … so the condition is universally true and the rule is a constant."*

The predicate is not that. It is:

```
match: requestCount >= 3 AND someWhere(requests, "agentMode", "agent") AND NOT (
  matches(first(requests).messageText, "(?m)^[-*]\\s") OR
  matches(first(requests).messageText, "(?m)^\\d+[.)]\\s") OR
  matches(first(requests).messageText, "(?m)^#+\\s") OR
  matches(first(requests).messageText, "(?i)\\b(requirements?|spec|…)\\b") OR
  lineCount(first(requests).messageText) >= 4)
```

The `someWhere` clause is one conjunct of three. The other two — a request-count floor and five
regex tests on the session's first user message — are entirely live and entirely captured. The
rule measures "what fraction of your sessions opened with an unstructured prompt", which is a
meaningful, varying quantity. It is not a constant.

Verdict: **implementable, we rationalized.**

#### `no-spec-driven-development` — the branch count is wrong

Our skip: *"Two of the rule's three OR branches would be dead."* There are **seven** OR branches,
not three: `specFileExts` over `first(requests).referencedFiles`, `specKeywords` over
`messageText`, `bulletList` + `lineCount >= 3`, `numberedList` + `lineCount >= 3`, `headings`,
`slashCommand == "plan"`, `contains(str(agentMode), "plan")`. Five are live from patterns carried
in the vendored frontmatter. Two are dead **for Copilot only** — and both are recoverable for
Claude Code via `permissionMode` (2.3.6) and `<command-name>` (2.3.5).

"2 of 3 dead" reads as a rule gutted past usefulness. "2 of 7 dead, and only on one harness" is a
modest fidelity note. The two framings support opposite decisions, and the wrong one was recorded.

Verdict: **implementable with stated cost** — the cost is a real, disclosable fidelity caveat on
the Copilot half, worth a line in the emitted signal rather than a skip.

#### `context-engineering-gaps` — "blocked" overstates it

`check: gapCount > 0 AND reqCount >= 30`, where `gapCount` sums five independent booleans:
sub-agents used, skills used, MCP tools used, file-reference rate, custom-instruction rate. Four
are computable from fields `telemetry.py` already produces (`agentName`, `skillsUsed`,
`toolsUsed` with `mcp_` prefix, `referencedFiles`). The fifth, `instrRate`, is the
`instruction-bloat` plumbing from 2.3.3 — **not unavailable**, just unbuilt. And `severity` keys on
`gapCount >= 4`, so a missing fifth gap changes a severity boundary, not whether the rule can
answer.

Verdict: **implementable, we rationalized.** Cost: strictly downstream of 2.3.3; the four other
gaps are already there.

#### `broken-flow-state` — the one honestly-stated skip

Needs `flowScoreStats` — `computeSessionFlowScore` in `src/core/analyzer-flow.ts` (275 lines
total; the scoring function plus per-day bucketing is roughly 100 of them). It is a genuine
four-component weighted score (rapid-followup rate 40%, median-latency band 30%, duration band
15%, request density 15%) with hardcoded breakpoints, aggregated into days and then a
`lowScoreRate`. All *inputs* (request timestamps, per-session duration, request counts) are
captured, so it is reachable — but the skip message's characterisation, *"porting that analyzer
rather than adapting a predicate"*, is exactly right.

Verdict: **implementable with stated cost.** ~150 lines of port with its own test surface. The
only entry in the table whose reason I would keep verbatim.

### 2.5 Verdict table

| # | Rule | Verdict | Blocking cost, if any |
|---|---|---|---|
| 1 | `no-devcontainer` | **genuinely unreachable** | upstream `VSCODE_HARNESSES` filter |
| 2 | `agent-mode-for-asks` | implementable, we rationalized | remediation text has no CLI referent |
| 3 | `agentic-no-tools` | implementable, we rationalized | — |
| 4 | `instruction-bloat` | implementable, we rationalized | read `workspace.yaml` / `cwd` |
| 5 | `no-skills` | implementable, we rationalized | — (field already captured) |
| 6 | `no-slash-commands` | implementable, we rationalized | Claude-only extractor; remediation objection |
| 7 | `no-plan-mode` | implementable, we rationalized | Claude-only |
| 8 | `profanity` | implementable, we rationalized | vendor MIT dictionary as hashes |
| 9 | `premium-waste` | implementable, we rationalized | vendor `MODEL_TIERS` |
| 10 | `premium-for-lookup-questions` | implementable, we rationalized | vendor `MODEL_TIERS` |
| 11 | `auto-avoidance` | implementable, we rationalized | vendor `MODEL_TIERS` |
| 12 | `session-drift` | implementable, we rationalized | vendor `WORK_TYPE_PATTERNS` |
| 13 | `verbose-prompt-no-compression` | implementable, we rationalized | — (patterns already inline) |
| 14 | `no-spec-structure` | implementable, we rationalized | — |
| 15 | `context-engineering-gaps` | implementable, we rationalized | downstream of #4 |
| 16 | `auto-approve-terminal` | implementable with stated cost | Copilot-only; scope-mapping decision |
| 17 | `yolo-mode` | implementable with stated cost | Copilot-only; scope-mapping decision |
| 18 | `no-custom-instructions` | implementable with stated cost | downstream of #4; always-fires risk |
| 19 | `no-file-context` | implementable with stated cost | needs a local rule id, not upstream's |
| 20 | `no-spec-driven-development` | implementable with stated cost | 2 of 7 branches dead on Copilot |
| 21 | `broken-flow-state` | implementable with stated cost | ~150-line analyzer port |

### 2.6 What a follow-up round would actually build

Ordered by value per line. Nothing here was written this round.

1. **`vendor/coach-rules/tables/`** + a `sync-coach-rules.sh` extraction step for `MODEL_TIERS`
   and `WORK_TYPE_PATTERNS`, each with a `_pin()` on the extracted content and a loud failure if
   the anchor is missing. Unlocks #9-12 — **four rules for one piece of infrastructure.**
2. **`verbose-prompt-no-compression`, `no-spec-structure`, `no-skills`, `agentic-no-tools`** —
   four adapters over fields already in `telemetry.py`. No new plumbing at all.
3. **Instruction-file plumbing** — `workspace.yaml` → folder → `.github/copilot-instructions.md`
   size for Copilot, `cwd` → `CLAUDE.md` for Claude. Unlocks #4, #15, and #18.
4. **`profanity`** — hashed dictionary + `stripCode` port.
5. **The permission mapping** — `approved-for-location` → `autoApproveScope: 'always'` for #16/#17,
   Copilot-only, disclosed as such.
6. **`broken-flow-state`** — the analyzer port, last, because it is the only one whose cost was
   stated accurately in the first place.

Steps 1-3 would take coverage from 24/45 to roughly **35/45** and none of them requires data this
project does not already read.

Whatever is decided, **`UNSUPPORTED_REASONS` must be rewritten regardless**, because twelve of its
entries currently assert things about upstream's source or this machine's data that are false. A
skip table whose reasons are wrong is worse than no skip table: it is the mechanism by which the
wrongness survives review.

---

## Part 3 — what is actually left against the agreement

Re-derived independently from `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md`.

### Independent verification of the prior audit's three PARTIALs

- **GC5 (reviewer must not get write tools) — now DONE.** Verified in the tree, not from a report:
  `scripts/session-review.sh:206-207` passes `--allowedTools "Read,Glob,Grep"` **and**
  `--disallowedTools "Write,Edit,NotebookEdit"`; `scripts/copilot-session-review.sh:103` is
  `COPILOT_ARGS=(-s --allow-tool read)`. Both halves of the constraint are mechanical now, not
  prompt text. Confirmed addressed.
- **Copilot credit ceiling — DONE.** `scripts/copilot-session-review.sh:128-132`: opt-in via
  `SL_COPILOT_MAX_AI_CREDITS`, guarded to integer `>= 30` (the CLI's own floor), and a rejected
  value warns on stderr instead of being silently dropped. Confirmed addressed. *Note: this was
  never a plan item — it is post-plan work, so it is a closed discovery, not a discharged debt.*
- **Verification Gate item 6 (live interactive Copilot session) — still PARTIAL.** Unchanged. See
  below.

**Discrepancy in the audited artifact, flagged as instructed.** `plan-vs-delivered-audit.md`'s
scoreboard (line 22) claims **3 PARTIAL**, but `grep -n "PARTIAL"` over the file returns only two
marked items (GC5 at line 88, Gate item 6 at line 290). Either a third was reclassified without
updating the scoreboard, or the count is wrong. The tree wins: **two** PARTIALs existed, one is
now closed, one remains.

### Verification Gate, re-checked at `3a3eec2`

| # | Gate item | Status |
|---|---|---|
| 1 | `tests/run-all.sh` passes locally | Passing per CI; not re-run locally this round (read-only) |
| 2 | `tests/test-claude-absent.sh` passes | Green in all six CI cells |
| 3 | All six CI matrix jobs green | **Verified live.** Run `30185809939`, `headSha == 3a3eec2`, six cells success |
| 4 | `doctor.sh` reports a legacy `~/.claude` store without moving it | Present: `doctor.sh:308-315` calls `paths.legacy_home()` and prints, never relocates |
| 5 | `grep 'claude'` over the three files finds no binary invocation and no `~/.claude` default | **Holds.** Three hits, all in `paths.py`, all inside `legacy_home()` — the deliberate legacy *detector* the plan's own back-compat constraint requires. Zero in `copilot-session-review.sh` and `persist-proposal.py` |
| 6 | Manual live check on Copilot CLI | **The one open item.** See below |

### The honest remaining-work list

**A. Owed under the agreement — 1 item**

1. **Verification Gate item 6's residual: no genuine *interactive* Copilot CLI session has fired
   `sessionEnd` with real conversation history in the hook payload.** Both sides of the seam are
   independently demonstrated — the hook script ran end-to-end for real with a paid model call,
   and the OUTPUT CONTRACT with a real transcript persisted real content at mode 0600 — but the
   two have never been observed in one continuous live run. Closing it costs one interactive
   Copilot session in ordinary use, not engineering. Everything else the plan agreed to is in the
   tree.

**B. Discovered later, deferred, not owed**

2. The 21 Coach skips analysed above (Coach belongs to the 2026-07-22 plan, not this one).
   Twelve are rationalizations that should be corrected in `UNSUPPORTED_REASONS` **whether or not
   the rules get implemented** — that correction is the only item in group B I would call urgent,
   because it is a documentation defect this branch has a demonstrated history of.
3. Windows write-path TOCTOU: the `CreateFileW` held-handle design is implemented, probe-gated
   and self-verifying, and green on both Windows cells at HEAD. Residual: it is verified by CI,
   never by a human on a Windows box.
4. Windows coverage is not equal coverage — 7 write-path security tests and 3 shell assertions
   skip there, each gated on a probe that confirms the limitation. Known, announced, unclosed.
5. Digests are assistant-heavy (7 user turns of 70 blocks in the Copilot sample). Recorded as a
   "first thing to try" if review quality disappoints. Untested hypothesis, no action owed.

**C. Genuinely out of scope (binding Out-of-Scope list)**

6. VS Code Copilot Chat hook spike and adapter.
7. Copilot `postToolUse` turn counting.
8. Measurement: usage reader, continuous holdout, reporting norms.
9. Failure-triggered review.
10. Install UX, install manifest, manifest-driven uninstall.
11. All `graphify-offline` work.

Two of the original eight deferrals were built anyway and are correctly recorded as such in the
plan's superseding callout: session-source adapters (forced by round P0 — both reviewers were
being spawned with no transcript, so every prior review was a paid call that could not learn
anything) and the deep security audit (`tests/test-adversarial-sweep.py`). The remaining six above
are correctly absent from the tree; I re-checked.

---

## Method note, and one thing I could not close

Everything upstream is cited to a file and line in a clone I made this session at `766d0f2`, not
to any summary in this repository. Everything about the data is a count I ran against the live
stores, read-only. Where a prior report and the tree disagreed, the tree is what is recorded.

What I did **not** do: implement anything, run the full suite locally, or spend a model call. The
single claim in this document I cannot fully discharge is Gate item 1 — I report CI's verdict on
`tests/run-all.sh`, not my own local run, because this round was read-only by instruction.
