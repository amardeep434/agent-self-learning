# Learned-context delivery — remediation plan, 2026-07-30

Companion to [`docs/upstream-audit-2026-07-30.md`](../../upstream-audit-2026-07-30.md),
which is the evidence. This file is the decision and the work list. Where the two
disagree, the audit wins — it carries the re-derivation commands.

**Status: DELIVERED 2026-07-30 (PR #12, merged), with one step outstanding.**

The decision in §2 was taken: **Route C, reached as B then A**. Both shipped.

- Route B — `scripts/session-start-context.py` + `.sh`, registered as `SessionStart`
  in all three templates.
- Route A — `scripts/mirror-skills.py`, publishing to `~/.claude/skills` and
  `~/.copilot/skills`, launched detached from the same hook.
- P0.1–P0.5 and P1.1–P1.3 are all closed. `use_count` (P0.2) was resolved by making
  the documentation honest rather than by inventing a signal no harness reports —
  see `tests/test-skill-usage-honesty.py`, which locks the two together in both
  directions.

**Outstanding, and it is the acceptance bar in §6, not a formality:** no hook has
been observed firing on Claude Code or VS Code. Copilot CLI's `sessionStart` is
registered and live; Claude Code registration is manual and is the user's step.
Until a real hook is observed producing the block, README's capability rows stay
⚠️ "wired, never observed firing" — a green matrix is not evidence a hook ran.

Three adversarial reviews after the fact found two CRITICAL defects in the
delivered code (ungated skill *bodies* reaching an auto-loaded directory, and a
marker check that let `prune()` delete the user's own skills) plus four HIGH. All
fixed in PR #12; see its description. Read that before trusting anything below as
still-accurate design intent.

---

## 1. What is actually broken

The system distils learnings correctly and delivers none of them. 46 learned skills and a
20,752-byte `MEMORY.md` sit in the store; nothing reads them back into a working session.
Every component exits 0, `doctor.sh` reports HEALTHY, and `README.md:335` claims the
feature ships on all three harnesses.

Two framings were wrong and are worth stating so they are not re-adopted:

- **"We need a SessionStart hook."** Partly wrong. All four upstreams we cite deliver by
  writing where the harness already looks, not by injecting through a hook. The root cause
  is that `<store>/learned-skills/` is a location no harness discovers.
- **"46 skill descriptions is too many to inject; we need relevance filtering."** Wrong.
  Hermes injects a full index at 70+ skills and forbids pruning it
  (`agent/prompt_builder.py:1789-1793`). **Do not build a relevance filter.**

---

## 2. OPEN DECISION — delivery route

Three routes, all upstream-attested. This is a product decision about where learned context
lives, not a technical one; the evidence does not settle it.

### Route A — mirror into the harness's native skill directory

Write each learned skill to `~/.claude/skills/<name>/SKILL.md` (and the Copilot/VS Code
equivalents) in addition to the store.

- **Upstream precedent, the strongest of the three.** SkillOpt writes
  `~/.claude/skills/skillopt-sleep-learned/SKILL.md`; GEPA writes
  `.claude/skills/<repo>/SKILL.md`; Coach writes `~/.agents/skills/<slug>/SKILL.md`.
- Needs **no hook at all**. Native discovery, progressive disclosure for free.
- **Cost:** writes into a harness-owned directory. This was previously rejected on
  harness-neutrality grounds — a project constraint no upstream shares. Rejecting it is
  legitimate; rejecting it while calling it a *design flaw* was not.
- Requires a per-harness target map and `uninstall.sh` cleanup.

### Route B — `SessionStart` hook injecting `additionalContext`

- **Upstream precedent:** Hermes' actual mechanism (system-prompt volatile tier), and what
  our own research corpus prescribed in at least four places
  (`02-self-learning-mechanisms.md:254`, `07-implementation-guide:237,5952,6693`).
- Matches `README.md:12`'s existing claim about a session-start snapshot.
- Touches no harness-owned directory — the neutrality objection does not apply.
- **Cost:** three hook registrations, two output shapes, and the contract is version-fragile
  (see §5).

### Route C — both

Not a third body of work. C is the **end state** in which A and B both exist: Route B
carries `MEMORY.md`, Route A carries skills. Most faithful to Hermes, which delivers memory
and skills through *different* channels for exactly this reason.

### Recommendation: reach C in two ordered steps

**Step 1 — Route B, for memory only.** The hook reads `MEMORY.md` and returns it as
`additionalContext`. This is required under every scenario: `MEMORY.md` has no
harness-native location, so no harness will ever discover it on its own. Injection is the
only available route for memory.

**Step 2 — Route A, for skills only.** Write each learned skill to
`~/.claude/skills/<name>/SKILL.md` and the Copilot/VS Code equivalents. Skills *do* have a
native home, so this needs no hook, and progressive disclosure comes free — name and
description in the prompt, body loaded on demand.

**Why this order.** Step 2 writes into a harness-owned directory and so crosses the
harness-neutrality rule; step 1 touches nothing under `~/.claude`. Doing step 1 first
delivers working memory read-back without settling the neutrality question, and leaves
step 2 to be judged on its own merits — including the option of declining it, in which
case memory is delivered and skills remain undelivered.

Prerequisites for step 1 are P0.1 (§3) and P1.1 (§4), not part of it.

---

## 3. P0 — fix regardless of which route is chosen

These are defects on the tree today. None depends on the decision above.

### P0.1 — `inject-agents-md.py` silently drops 89% of memory

`scripts/inject-agents-md.py:33` slices `[:2200]` on the read side: no ellipsis, no
`persist-failures.log` line, nothing `doctor.sh` can surface. Against the live 20,752-byte
`MEMORY.md` that injects 10% and discards 89%, mid-entry.

Hermes uses the same 2200 as a **write-side** budget that refuses the write and demands
consolidation (`tools/memory_tool.py:165`, rejection `:426-437`).

**Fix:** move the budget to the write path in `persist-proposal.py` — refuse an append that
would exceed it, with a named reason telling the reviewer to consolidate. The read path
must never truncate. If a cap on the read path is kept as a backstop, exceeding it is a
logged failure, not a silent slice.

**Acceptance:** a proposal that would overflow the budget produces a
`persist-failures.log` line naming consolidation, and `MEMORY.md` is unchanged. Mutation
test: revert the guard, confirm the test fails.

### P0.2 — `use_count` is never incremented

All 50 tracked skills read `use_count: 0`; `view_count` is absent from every record. No
incrementer exists in `scripts/`. So `prompts/curator-review.md:51`'s `AND use_count > 0`
archival gate is unreachable and `:55`'s reactivation-on-`view_count` reads a field never
written. The curator archives on wall-clock staleness alone.

**Fix — decide first, then implement.** Either wire a real usage signal (hard: requires the
harness to report skill invocation, which none of our three does today), or **delete the
usage-gated branches and document that archival is wall-clock only.** The second is
honest and small; the first may not be achievable on any current harness.

Do not leave it as-is: a gate that cannot fire reads as coverage that does not exist.

**Acceptance:** either `.usage.json` shows a nonzero `use_count` after a real skill
invocation, or `curator-review.md` and `skill-lifecycle.py` no longer reference a field
nothing writes.

### P0.3 — MIT notice clause unsatisfied

45 verbatim rule files plus two verbatim `.ts` slices are substantial portions.
Microsoft's copyright appears nowhere in the repo; extraction dropped upstream's file
header from both `tables/*.ts`.

**Fix:** add Microsoft's copyright line and the MIT permission notice to
`vendor/coach-rules/`, and restore the dropped header on the two extracted slices.
`vendor/coach-rules/tables/profanity-sha256.txt:3` is the in-repo template for how.

**Acceptance:** `grep -rn "Copyright (c) Microsoft" vendor/` is non-empty.

### P0.4 — Route B export ignores `schemaVersion`

`coach-export-read.py` has zero references to the version upstream stamps
(`summary-export.ts:39`) precisely so consumers can refuse an incompatible payload. A
`schemaVersion: 2` that re-semanticises `occurrences` would be consumed silently with the
wrong denominator.

**Fix:** guard on `schemaVersion == 1`, failing loudly otherwise, in the idiom already at
`coach-export-read.py:60-67`.

Separately, re-word the "32,929 occurrences → 10 signals" framing: **10 is upstream's
`TOP_ANTI_PATTERN_LIMIT` cap**, not a reduction we performed. Route B can never surface an
11th anti-pattern however prevalent.

### P0.5 — two false/overstated documentation claims

- `README.md:335` — `| AGENTS.md learned-context injection | ✅ | ✅ | ✅ |` is false in all
  three columns (0 of 175 `AGENTS.md`/`CLAUDE.md` files carry the managed block). Either
  ship the feature in this same change or mark the row honestly. Do not fix the row and the
  feature in separate commits that each look complete.
- `no-devcontainer`'s skip reason claims structural unreachability. It is unreachable
  because `telemetry.py` has no VS Code source — plain VS Code is labelled `'Local Agent'`,
  which **is** in upstream's `VSCODE_HARNESSES`. Re-word to "unreachable while no VS Code
  session source is plumbed into `telemetry.py`" — checkable, falsifiable, and pointing at
  work rather than away from it.

---

## 4. P1 — required before any injection ships

### P1.1 — threat gate on the read path (blocking for Route B or C)

Whatever we inject is LLM-authored content derived from arbitrary session transcripts. It
becomes a prompt-injection channel into every future session.

Hermes scans each entry at snapshot-build time and substitutes `[BLOCKED: …]` in the
**injected** text while leaving the raw entry on disk for the user to see and remove.

Coach ships the stronger mechanism for exactly this input class — spotlighting via
datamarking (`src/core/spotlight.ts:6-21`), whose own guidance names transcript snippets as
the first thing to datamark and reserves plain delimiting for content whose formatting must
be preserved. We currently use delimiting (`scripts/lib/review-common.sh:132`), which is
upstream's option for the *other* case.

**Ordering constraint upstream had to discover:** redaction must run **before** datamarking,
because some redaction patterns depend on whitespace (`spotlight.ts:29-33`). We already have
the redaction half (`scripts/lib/transcript.py:267`, applied `:571,:700,:841`).

**Do not ship injection without this.**

### P1.2 — handle `SessionStart` with `source: "compact"`

Claude Code fires `SessionStart` on `startup, resume, clear, compact, fork`. Compaction is
the only point at which a session can see its own learnings — Hermes reloads memory from
disk there deliberately (`agent/system_prompt.py:576-585`). A startup-only hook misses it.

This also means the hook runs repeatedly per session, so it must be cheap and idempotent
(hook budget <100ms).

### P1.3 — if a skill index is ever cached, every writer must invalidate it

Upstream invalidates its snapshot from six call sites. Our writers include
`curator-run.sh`, which **archives and deletes skills** — a stale cache would advertise
archived skills. Simplest correct choice: do not cache.

---

## 5. Implementation contract for Route B

Two shapes, both measured:

| harness | shape |
|---|---|
| Claude Code, VS Code | `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}` |
| Copilot CLI | `{"additionalContext":"…"}` |

**Do not emit both keys in one object.** It works, but Claude Code ships a warning written
for exactly that mistake and logs it every session start, and Copilot's native struct
already honours `hookSpecificOutput` for `preToolUse` compat — extending that to
`sessionStart` would turn the trick into a real double injection.

Claude Code and VS Code need no distinction from each other (identical payload), so the
`--harness auto` transcript sniffing is **not** needed here. Discriminate structurally on
the stdin payload: Copilot sends camelCase `sessionId`/`timestamp`; Claude Code and VS Code
send snake_case `session_id`/`transcript_path`.

**Copilot concatenates all non-progress stdout and runs one `JSON.parse`.** A single stray
`echo` silently kills the injection. All diagnostics go to `persist-failures.log`, never
stdout. This is the one place where hard rule §2 and the wire format actively conflict —
design for it rather than discovering it.

Note VS Code reads `~/.copilot/hooks` too, so a Copilot-shaped hook also fires there and
its flat output is silently dropped. Discriminating on the payload rather than on which
config file invoked us avoids a per-thread silent no-op.

---

## 6. Acceptance bar

**A real fired hook, not a green unit test.** No hook has ever fired on Claude Code or
VS Code; every harness verdict in the audit except Copilot's is static analysis, and the
Copilot one came from invoking `runtime.node` directly rather than from a session.

Minimum evidence for "done":

1. A real Claude Code session start produces the managed block or the injected context, with
   a byte-count before and after — never the emptiness of a command's output.
2. The same on Copilot CLI, with `persist-failures.log` empty and nothing written under
   `~/.claude`.
3. VS Code observed at least once, or the adapter documented as still-unfired. Do not let a
   green matrix imply it.
4. `MEMORY.md` content arrives **untruncated**, verified by comparing store bytes to
   injected bytes.
5. A threat-gate test: a memory entry containing an injection attempt appears as
   `[BLOCKED: …]` in the injected text and unchanged on disk.

Re-derive the Copilot contract after any `copilot` self-update — the engine moved from JS
to Rust between 1.0.70 and 1.0.75, and `~/.cache/copilot/pkg/linux-x64/<version>/app.js`
makes that cheap.

---

## 7. Explicitly out of scope

- **Relevance filtering / retrieval.** Upstream forbids it for the index. If retrieval is
  ever wanted, Hermes' seam is an additive memory *provider* (`plugins/memory/`, 10 RAG
  backends), never a filter on the wholesale block.
- **SkillOpt's MCP server.** Skipping it costs nothing — MCP is a Copilot-specific
  invocation transport wrapping the same CLI verbs, not a delivery mechanism.
- **Widening skill descriptions from 60 chars.** Upstream uses 300-600 char trigger-rich
  descriptions and, if a description is what an agent selects on, 60 may be below the
  threshold where selection works. Real concern, but it is a prompt/authoring change with
  its own evidence needs — do not bundle it here.

---

## 8. Known-unverified, carried forward

- Whether Coach's 12 `languageModelTools` are reachable from general VS Code agent mode or
  only from `@aicoach`. If reachable, upstream has a working agent-facing pull surface and
  §2's framing changes. **Most decision-relevant unknown.**
- Whether Hermes' builtin memory provider has a per-turn `prefetch(query)` path (its auditor
  flagged this as its own likeliest error).
- Whether a plumbed VS Code telemetry source would actually make `no-devcontainer` fire.
- Everything here is Linux-measured. No Windows or macOS verification of any finding.
