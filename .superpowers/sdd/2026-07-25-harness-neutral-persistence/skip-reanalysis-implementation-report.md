# Skip re-analysis — implementation report

Date: 2026-07-26
Branch: `harness-neutral-persistence`, starting at `6025293` (the audit commit)
Spec: `skip-reanalysis-audit.md`, this directory. Read that first; this is what was
built against it.

Coverage: **24/45 → 42/45.** Three rules remain skipped, each with a reason that
cites either an upstream file and line or a measurement re-run this session.

Commits, one per logical change, each green on `bash tests/run-all.sh` before the
next was started:

| SHA | What |
|---|---|
| `aaeef78` | rewrite all 21 skip reasons to cite checkable evidence; two tests enforce it |
| `156cbbf` | no-skills, agentic-no-tools, no-spec-structure, verbose-prompt-no-compression |
| `6aa2491` | vendor MODEL_TIERS + WORK_TYPE_PATTERNS → premium-waste, premium-for-lookup-questions, auto-avoidance, session-drift |
| `4dc268d` | workspace instruction-file plumbing → instruction-bloat, no-custom-instructions, context-engineering-gaps |
| `8ee4b80` | profanity, from a hashed leo-profanity dictionary |
| `ad171a5` | `approved-for-location` → `autoApproveScope: 'always'` → yolo-mode, auto-approve-terminal |
| `d5a74ff` | slashCommand + plan-mode marker → no-slash-commands, no-plan-mode, agent-mode-for-asks, no-spec-driven-development |

Suite: 43 suites, unchanged in count, all passing. Python suites run under
`~/.pyenv/versions/3.9.24/bin/python3.9`. Coverage pin moved 13 → 31 telemetry
adapters in step with each commit.

---

## Where the audit was wrong

The audit is an artefact, not scripture, and two of its claims did not survive
re-measurement. Both mattered.

**1. `no-plan-mode` / `permissionMode`.** The audit proposed mapping upstream's
plan-mode test onto Claude Code's `permissionMode`, reporting `plan` 0 alongside
`dontAsk` 3378 and treating the zero as "the rule would fire as a true positive".
Re-measured over 727 local transcripts: `permissionMode` is `default` 377,
`acceptEdits` 853, `auto` 901, `dontAsk` 3378 — and **never once `plan`**.
Mapping the rule onto `permissionMode` would have produced a rule that fires on
every corpus forever — the always-fires failure the audit itself flags for
`no-custom-instructions`, reintroduced two sections later. The `ExitPlanMode`
tool use is the correct marker, and is what shipped.

> **Correction, added in the follow-up round.** The sentence that used to sit here
> — "the `ExitPlanMode` tool appears **780 times**. Plan mode is plainly used" —
> was itself wrong, and wrong in exactly the way this section criticises. 780 was a
> raw `grep -c`; the coordinator independently got 822 the same way. Transcripts
> carry the harness's own tool listing as ordinary text, so the literal appears in
> every session that merely had the tool available. Structurally: **368 of 739
> transcripts contain the literal, and exactly ONE contains a real `tool_use`
> block.** Plan mode is barely used here, so the finding is very likely TRUE. I
> made the same class of error I had just flagged in the audit's `<command-name>`
> count, one section later, and did not catch it until a scan for an impossible
> marker string returned a hit — from the transcript of the session running the
> scan. `telemetry.py` reads `tool_use` structurally, so the shipped rule was
> always counting real uses; only the report's evidence sentence was wrong.

The brief inherited this and went further, offering `permissionMode` as "a real
ask/agent analogue" for `agent-mode-for-asks` and `agentic-no-tools`. It was not
used for those either, and the audit's own reasoning is why: `default` /
`acceptEdits` / `dontAsk` / `auto` are permission postures and all of them are
agentic. Those two rules use the no-op reading of the tautological conjunct
instead, which the brief also endorses and which needs no invented field.

**2. `<command-name>` counts.** The audit says 133, the brief says 142. Parsed out
of user-message content across 727 transcripts I get **65 invocations, 13
distinct**, `/model` ×23 the most frequent; a raw `grep -c '<command-name>'` over
the same tree gives 237, which counts sidechain and assistant echoes. The
qualitative claim — Claude Code records slash commands and the old measurement
never looked — holds. The number does not; 65 is what the shipped skip-history
text records, with its method.

Everything else in the audit reproduced. `approved-for-location` is 7 corpus-wide.
`instruction-bloat`'s `workspace.yaml` is present in every session directory (137
found). Both regexes for `verbose-prompt-no-compression` are literals in the
vendored detect block. `profanity.ts` carries no wordlist.

---

## Per rule

### Implemented (18)

| Rule | Evidence the skip was wrong | Fire test | Mutation |
|---|---|---|---|
| `no-skills` | detect block is `skillsUsed.length == 0`; the field is captured for both harnesses, as the skip message itself said one clause earlier | fires on 60 skill-free turns; silent when ONE turn anywhere uses a skill (`count == total`) | 1/1 killed |
| `agentic-no-tools` | tautological disjunct is a no-op; `toolsUsed` does all the work | fires on 15 no-tool turns; silent when turns call tools | 1/1 |
| `no-spec-structure` | `someWhere(agentMode)` is 1 of 3 conjuncts; the others are a request floor and five regexes on the first prompt | fires on unstructured openings; silent on bulleted, on 4-line, and below the floor | 2/2 |
| `verbose-prompt-no-compression` | both regexes are literals in the vendored detect block | fires on long fluffy prompts; silent on long terse, single-filler, short-fluffy, and when a compression skill exists anywhere | 4/4 |
| `premium-waste` | `MODEL_TIERS` is a literal at `interpreter.ts:267-284` | fires on short promptless premium turns; silent on a tier-0.3 model, on long prompts, and when code was produced | 2/2 |
| `premium-for-lookup-questions` | same table; the opener regex is inline | fires on question openers; silent on imperatives and when tools ran | 2/2 |
| `auto-avoidance` | same table plus one regex over a captured field | fires on a dominant premium model; silent with `auto` present, non-premium top, or no dominance | 3/3 |
| `session-drift` | `WORK_TYPE_PATTERNS` is a literal at `interpreter.ts:303-313` | fires on 5 work types in a session; silent on 5 same-type prompts and under the per-session floor | 2/2 |
| `instruction-bloat` | upstream reads it FOR CLI sessions via `isCLI` (`parser-vscode.ts:118`) | fires on a 9000-byte instruction file; silent on lean/absent; counts one workspace once; skips when no workspace resolves | 2/2 |
| `no-custom-instructions` | the field is set only by `parser-vscode-request.ts:387` — an adaptation, see below | fires when no workspace has a file; silent when they do and at a mixed rate | 2/2 |
| `context-engineering-gaps` | 4 of 5 gaps were already computable; `severity` keys on `gapCount >= 4` | fires with all 5 gaps open (count 5); silent with all closed; returns 3 with two closed | 5/5 |
| `profanity` | upstream ships no wordlist either; it depends on `leo-profanity` 1.9.0 (MIT) | fires on a hostile prompt; silent on civil, fenced code, inline code, substring; matches through trailing punctuation | 4/5, 1 equivalent |
| `yolo-mode` | numerator is 7, not 0; upstream applies no latency test | fires at 100% persisted approvals; silent on one-shot, at the real 7/331 ratio, below the floor, and per-confirmation vs per-request | 5/5 |
| `auto-approve-terminal` | same measurement; `isTerminal` ← `kind == "shell"` | fires on persisted shell approvals; silent on non-shell, on one-shot, below totals | 3/3 |
| `no-slash-commands` | Claude records `<command-name>` blocks; never measured before | fires when nobody uses one; silent on Claude command blocks, Copilot leading slash, and a mixed 0.05 rate | 2/2 |
| `no-plan-mode` | Claude has plan mode; `ExitPlanMode` is the marker | fires when never used; silent on `ExitPlanMode`, on `/plan`, below the floor | 4/4 |
| `agent-mode-for-asks` | seven live conjuncts behind one tautology | fires on short barren turns; silent when turns use tools and on long prompts | 2/2 |
| `no-spec-driven-development` | seven OR branches, not three | fires on bare openings; silent on keyword, bullet, spec-file reference, and plan-mode openings; below the floor | 5/5 |

Plus infrastructure mutants: vendored-table pin, extraction anchor, model-tier
ordering, `normalize_model_id`, `_join_continuations`, `strip_code` (both passes),
`hash_dictionary`'s shape guard, the `workspace.yaml` absolute-path guard, the
`SUGGESTION_OVERRIDES` substitution, and both `slashCommand` extractors.

**Mutation totals: 74 mutants, 72 killed, 2 equivalent, 0 surviving.** Nine
mutants survived a first round; every one was a real test gap and each is
described in the commit that closed it. The two equivalents are annotated in code:
`model_tier`'s date-suffix strip (matching is substring containment, so stripping
can only remove a match) and `profanity`'s `messageLength > 0` conjunct
(`contains_profanity("")` is already False). Both are kept because the functions
are transcriptions of upstream's and a transcription that quietly drops a line
stops being diffable.

### Still skipped (3), with the accurate reason

- **`no-devcontainer` — genuinely unreachable.** `computeDevcontainerStats` opens
  with `sessions.filter(s => VSCODE_HARNESSES.has(asStr(s.harness)))`
  (`interpreter.ts:579-583`). For a CLI harness the population is empty inside
  upstream's own function, by a hardcoded gate, before any field of ours is read.
  The audit is right that this is the one genuine skip and right that the old
  wording ("needs a vscode-vs-terminal request classification") under-explained it.
- **`broken-flow-state` — deferred, cost stated.** A four-component weighted
  per-session score with hardcoded breakpoints, bucketed per day
  (`analyzer-flow.ts:41`). Every input is captured. ~150 lines of port with its own
  test surface. This is the audit's own recommendation and I agree with it.
- **`no-file-context` — reachable, deliberately not under this rule id.** Upstream
  means human-attached prompt context; Copilot records it as
  `user.message.data.attachments` (5 of 156 local user messages carry them). But
  `telemetry.py` populates `referencedFiles` from tool arguments, mirroring
  upstream's own CLI parser, and four shipped adapters depend on that definition.
  Redefining it for one rule is the drift `_pin()` exists to prevent. It wants a
  locally-named signal with its own suggestion text.

---

## Adaptations, each declared as one

Every divergence from upstream's field is stated at the point it is made, in the
adapter or in `telemetry.py`, and repeated in `README.md`.

1. **`CLAUDE.md` for `.github/copilot-instructions.md`.** Same question (how many
   bytes of always-on instructions does this workspace push into every request);
   different filename, necessarily.
2. **`customInstructions` redefined per workspace.** Upstream can distinguish two
   requests in the same workspace; this cannot. The alternative was a rule that
   fires on every corpus, which looks like a finding.
3. **`approved-for-location` → `autoApproveScope: 'always'`.** Copilot has no
   session-scoped approval, so upstream's `'session'` arm is dead here. Claude Code
   records no confirmations at all, so these two rules are Copilot-only — a real
   coverage gap, not a mapping choice.
4. **`ExitPlanMode` as Claude Code's plan-mode marker.** Upstream has no Claude
   plan-mode mapping; `permissionMode` is measurably the wrong field.
5. **Tautological conjuncts dropped as no-ops** in `agentic-no-tools`,
   `no-spec-structure`, `agent-mode-for-asks`, `no-plan-mode`,
   `context-engineering-gaps`. For `no-spec-structure` the denominator is unchanged,
   because upstream's own `agentSessionTotal` does not filter on agent mode either.
6. **`SUGGESTION_OVERRIDES`.** `no-slash-commands` and `agent-mode-for-asks` are
   real findings whose upstream remediation names commands and a mode neither CLI
   has — and the suggestion is what gets persisted into memory. The finding ships;
   the text is replaced, marked `ADAPTED FOR CLI`, declared in one table rather than
   buried, and asserted by two tests to actually reach the emitted signal.

---

## Two defects found while transcribing, both fixed

- **`eval_vibe_coding` was missing the `lineCount >= 4` OR-branch** that
  `no-spec-structure` carries identically, so it over-fired on sessions whose
  opening prompt was a four-line paragraph with no bullets, heading or requirement
  keyword. Found by writing out the branch list for the new rule and diffing it
  against the code already present. Both now share one `_is_spec_shaped()`.
- **`parse_rule` split the detect block on physical lines**, so for the seven rules
  that fold a clause with a trailing backslash, `_pin()` was guarding only the
  first line — an upstream edit to any continuation line would have slipped past
  the drift guard. Lines are joined before parsing; disabling the join fails four
  tests.

One upstream defect is recorded rather than fixed: the vendored `no-plan-mode`
detect block's `planUsage` line is corrupted (`"(?i)plan"slashCommand", "plan")` —
an unbalanced quote). The intent is unambiguous from `hasPlanning`. `_pin()` holds
the adapter to the corrupted text, so if upstream fixes the typo the adapter stops
rather than silently answering the old shape.

---

## What the skip table is now

`UNSUPPORTED_REASONS` has three entries. Two tests hold the line:

- every reason must carry `[upstream <file>:<line>]`, `[vendored <rule>.md ...]` or
  `[measured ...]` — five reasons failed this assertion while being written and
  were fixed, which is the test doing its job on the day it was added;
- the table may only name rules that exist, so a stale entry cannot become dead
  text no reader can catch.

Two arguments are banned outright in the header, because both were load-bearing
for the false skips: `requiresIdeContext` as proof of unreachability, and "a
constant conjunct makes the rule a constant".

The standing principle is unchanged and was not used as cover in either
direction: no rule joined the evaluated set without a fire/no-fire test pair over
fixtures built from real event shapes, and the three that remain skipped are
skipped for reasons that survive being checked.


---

# Follow-up round — persisted-artifact verification and absence scoping

Two items from the coordinator, after the 42/45 work landed. Branch tip was
`fddcc4a` (three commits of theirs, none touching Coach files; CI run
`30210446428` green on all six cells).

| SHA | What |
|---|---|
| `0608bb8` | overrides fit the sanitize cap; absence findings disclose their window |
| `b6189b0` | `no-plan-mode`'s absence becomes a whole-corpus claim |

43 suites, count unchanged, all green. Python suites under
`~/.pyenv/versions/3.9.24/bin/python3.9`. Coverage unchanged at 42/45.

## 1. Does `ADAPTED FOR CLI` survive into persisted output?

**The marker did. The advice did not.** Verified by running the real
`coach-signals.py` merge and reading `coach-signals.json`, not by reading code —
which is the only reason this was found.

`coach-signals.py` sanitizes every suggestion to **240 characters** before it can
reach a reviewer prompt or the memory file. `no-slash-commands`' override was 380+,
so what got persisted ended:

```
... Define project-level ones for the tasks you repeat (Claude Code: .claude/com
```

Cut mid-word. The `ADAPTED FOR CLI` prefix survived because it is first; the half
that says what to do *instead* did not. That inverts the argument for the
substitution: marking the adaptation was what made replacing Microsoft's text
honest, and the replacement never arrived. It was worse than either shipping
upstream's text or skipping the rule.

Both overrides are now under the cap (233 and 219 chars) and arrive whole;
`OVERRIDE_MAX_CHARS` is a tested contract, and a test asserts the **final
sentence** of the persisted string, not just the prefix, so a re-lengthened
override fails even though the marker would still survive. The cap itself is
untouched — it is a security control on untrusted input.

Two of *upstream's own* suggestions (`instruction-bloat`,
`reasoning-effort-overuse`) are still truncated at 240. That is upstream's advice
being shortened, which is a cost; ours being cut in half changed what it said,
which was a defect.

**Not verifiable without a paid model call, and not claimed:** the final hop from
the reviewer prompt into `MEMORY.md` is model-authored. What is proven is that the
complete override text reaches `coach-signals.json` and is rendered into the
prompt line the reviewer reads.

## 2. Absence over a capped window

Both options were implemented, because they answer different halves.

**Option 1, generally** (`0608bb8`). `MAX_SESSIONS` caps the parsed sample. For a
**rate** that is sound — a rate over the newest N sessions is an estimate of a
rate, which is what a sample is for. For an **absence** it is not. The three rules
whose check is driven by a never-happened boolean (`no-skills`, `auto-avoidance`,
`context-engineering-gaps`) now carry a scope note naming the **actual** number of
logs read, not the cap, so a corpus smaller than 40 is not described as "the
newest 40". Rate-driven rules deliberately get no note — annotating those too
would make the note noise and teach the reader to skip it.

The note travels in **its own field**, not appended to `suggestion`. Appended, it
would fall past the same 240-character cap that mangled the overrides and vanish.
A caveat that can be truncated away is worse than no caveat, because the claim
survives without it. Both review scripts' jq renders it: a field the renderer
drops is a field that does not exist.

**Option 2, for the one marker where it is sound and cheap** (`b6189b0`).
`MAX_SESSIONS` is untouched. `telemetry.corpus_used_tool()` answers one narrow
question over every log on disk. Measured on the development corpus (387 MB, 814
logs, warm cache): **0.20s when the answer is no, 0.98s worst case**, on the review
path beside a model call.

**The obvious implementation would have been silently wrong.** A trial scan for a
marker string that could not exist returned a hit — from the transcript of the
session running the scan, which contained the string because it had just been
typed. Following that up produced the correction at the top of this report: 368 of
739 transcripts contain the literal `ExitPlanMode`, exactly **one** contains a real
`tool_use`. A substring scan would have answered "used" for anyone who merely had
the tool available and switched the rule off permanently and silently — a
dead-rule outcome dressed as a fix for a vacuity problem. The prefilter now only
nominates candidates; the answer always comes from the structural records.

Three answers kept distinct, all three driven by tests: **used anywhere** → silent;
**never used** → whole-corpus claim with a scope note saying so; **ceiling hit** →
the finding the sample supports, with a note saying that is all it is. `None` is
not `False`.

**Why only this rule got a scan.** It has a single unambiguous marker. The other
three are ratio- or multi-marker-shaped; a per-marker scan for each would cost
several corpus passes to answer what the disclosure already answers honestly. The
inconsistency between them is *disclosed* — one says "every session log on disk",
the others name their window — which is the point.

## Mutation

18 mutants across the two commits, **18 killed, 0 survived**. Five survived a
first round and every one was a real gap: truncating an override past the cap;
dropping `scope` in the merge step; dropping it in the renderer; the byte ceiling;
the Copilot half of the corpus scan; and the undetermined path. Closed by a
telemetry unit suite (`CorpusUsedToolTest`) and an in-process test that drives the
three scan answers directly, because the subprocess boundary cannot express "the
ceiling was hit" without an env knob whose only purpose would be testing.
