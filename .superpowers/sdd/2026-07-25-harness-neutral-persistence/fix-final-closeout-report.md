# Final Closeout Round — `harness-neutral-persistence`

**Branch:** `harness-neutral-persistence` · **Base for counts:** `befd131`
**Mode:** validate-then-fix. Every item below was re-derived by execution before any code was
touched, per the governing instruction: *"before you start fixing, double check if that change is
actually valid and needed."*

**Commits produced by this round (5):**

| SHA | Subject |
|---|---|
| `17fb9d1` | `fix(review): deny file-write tools to the Claude Code reviewer (GC5)` |
| `b9ea8ea` | `feat(review): opt-in cost ceiling for the Copilot reviewer (SL_COPILOT_MAX_AI_CREDITS)` |
| `4feec43` | `fix(persist): refuse case-folding skill-name collisions instead of destroying content` |
| `4895bd8` | `docs(plan): mark superseded passages in place and record the post-plan rounds` |
| `04b9c16` | `docs: re-verify every claim in README.md and CLAUDE.md against the tree` |

**Suite:** `bash tests/run-all.sh` → `Discovered 41 suite(s): 29 shell, 12 python. Ran 41. All 41
suites passed.` The 41-suite count did not drop; no suite was added or removed, only extended.

**Python 3.9** (`~/.pyenv/versions/3.9.24/bin/python3.9`): `compileall -q scripts tests` clean;
all 12 Python suites pass under that interpreter, run individually.

---

## A1 — Claude Code reviewer spawned with default file-write tools

**Verdict: validated real, fixed.**

### What was validated

The brief warned not to assume the flags exist or are spelled as guessed. Checked against the
installed binary (`claude --version` → `2.1.220 (Claude Code)`):

```
$ claude --help
  --allowedTools, --allowed-tools <tools...>
      Comma or space-separated list of tool names to allow (e.g. "Bash(git *) Edit")
  --disallowedTools, --disallowed-tools <tools...>
      Comma or space-separated list of tool names to deny (e.g. "Bash(git *) Edit")
```

Documented — but "documented" is not "accepted", and this round did not stop there. The exact
argv the fix builds was run against the real binary with an empty prompt (rejected before any
model contact, so no tokens):

```
$ claude --allowedTools "Read,Glob,Grep" --disallowedTools "Write,Edit,NotebookEdit" \
         --max-turns 16 --output-format text -p ""
Error: Input must be provided either through stdin or as a prompt argument when using --print
```

It reaches prompt validation, i.e. argv parsed cleanly. The existing control experiment in
`tests/test-review-cli-flags.sh` establishes that this CLI *does* emit `unknown option` for a
bogus flag, so "no unknown-option error" is a real acceptance signal rather than silent-ignore.

**Constraint genuinely unmet elsewhere?** Yes. `grep -rn 'allowedTools' scripts/ config/` had zero
hits before this round; `scripts/session-review.sh:180` spawned `claude -p … --max-turns …
--output-format text` and nothing else. The only thing stopping a write was the prompt's "Do NOT
write, create, or edit any file" — which a poisoned transcript can argue with.

**Reads preserved?** The reviewer reads `MEMORY.md`, `USER.md` and scans the skills directory, and
the prompt already tells it "You may ONLY use Read, Glob, and Grep tools". The restriction is
written as *those reads, no writes* — `--allowedTools Read,Glob,Grep` — not "no tools".

**Why both flags, not just the allow list.** `--allowedTools` is an auto-approve list. A host's
own `settings.json` `permissions.allow` can still grant `Write`/`Edit` to any session on that
machine, and this reviewer inherits that settings file. Deny rules take precedence, so
`--disallowedTools` is the half that actually makes the constraint hold independently of host
configuration. This is stated in-file so it does not read as redundant belt-and-braces.

Comma-separated single tokens (the help text permits comma or space separation) so a variadic
option can never swallow the flag after it.

### Mutation results — 2 killed, 0 survived

| Mutation | Result |
|---|---|
| Remove `--disallowedTools …` from the spawn | **KILLED** — `FAIL: reviewer argv denies the file-write tools` |
| Remove `--allowedTools …` from the spawn | **KILLED** — `FAIL: reviewer argv still permits the read tools it needs` |
| Restored | 0 failures |

### Note on the test, worth recording

The first draft of the argv assertion used `grep -m1 '^ARGS:'` and **failed against a correct
implementation**: the review prompt is multi-line, so the shim's `echo "ARGS:$*"` spans many
lines and the flags land well past the first. Corrected to grep the whole log, and the reason is
written into the test — that false-negative shape is exactly what this suite exists to avoid.

### Only CI can confirm

Nothing. Both binaries are present locally; this item is fully verified here.

---

## A2 — Copilot reviewer has no cost ceiling

**Verdict: the brief's premise was half-wrong; wired anyway, as an opt-in knob.**

### What was validated

The brief said an earlier round enumerated the flags and did not list `--max-ai-credits`, and
asked whether it still exists. **It does.** That earlier conclusion was wrong.

```
$ copilot --version
GitHub Copilot CLI 1.0.75.

$ copilot --help | grep max-ai
  --max-ai-credits <credits>            Set max AI credits for this session

$ copilot help limits
Session Limits Controls:
  Session limits are opt-in. …
    - In non-interactive prompt runs, usage accumulates across the whole run.
    - Subagents share the same session limit as the parent session.
  Options:
    --max-ai-credits <credits>
        Maximum AI credits for this session.
        Minimum: 30 AI credits.
  Accounting:
    - The AI credit limit is a soft cap: usage is known only after a model response returns.
      A response can therefore exceed or exhaust the limit before the CLI can observe that it
      has done so; the next model call is then blocked.
```

Semantics for non-interactive runs, minimum value, and acceptance all established directly:

```
$ copilot --max-ai-credits 30 -p ""
No prompt provided. …                       # parsed fine, reached prompt validation

$ copilot --max-ai-credits 5 -p ""
error: option '--max-ai-credits <credits>' argument '5' is invalid. …Use at least 30 AI credits.

$ copilot --sl-definitely-not-a-real-flag -p ""
error: unknown option '--sl-definitely-not-a-real-flag'
```

### The decision, and why the default is OFF

The brief invited a judgement on whether a ceiling belongs on by default. **It does not**, and the
deciding evidence is the third command above: **`copilot` errors on unknown options.** Passing
`--max-ai-credits` unconditionally would hard-break the *entire review* on any Copilot CLI older
than the release that added the flag. The review runs in a detached pipeline, so the only symptom
would be lines accumulating in `persist-failures.log` while learning quietly stopped — this
project's signature failure mode, and strictly worse than the runaway a default ceiling would
prevent. The cap is also *soft* on GitHub's side, so it bounds a runaway loop rather than any
single call; that is a guard-rail, not a normal-path constraint, which further weakens the case
for defaulting it on.

So: `SL_COPILOT_MAX_AI_CREDITS`, empty by default, documented in `config.sh`, `README.md`
("Bounding reviewer cost"), and the environment table. Values below 30 or non-numeric are refused
*in-script* with a named reason on stderr, rather than handed to a binary that would exit non-zero
inside a detached pipeline where nobody reads it.

### Mutation results — 2 killed, 0 survived

| Mutation | Result |
|---|---|
| Weaken the minimum from `>= 30` to `>= 1` | **KILLED** — 2 failures (`below-minimum credit value dropped from argv`, `…reported on stderr`) |
| Never append the flag to `COPILOT_ARGS` | **KILLED** — `FAIL: credit ceiling reaches argv when set` |
| Restored | 0 failures |

Seven new assertions in `tests/test-copilot-session-review.sh` pin all three states (absent when
unset, present when legal, dropped when illegal or hostile), each gated on the pipeline's
completion marker so the negative-shaped ones cannot pass vacuously. Four new assertions in
`tests/test-review-cli-flags.sh` pin the flag, the number 30, and a Copilot-side control
experiment against the real binary — no model calls, no tokens.

### Only CI can confirm

Nothing locally. CI runners have no `copilot`, so `test-review-cli-flags.sh` reports its skip
loudly there — by design, and unchanged by this round.

---

## A3 — Case-fold skill collision loses content

**Verdict: validated real, fixed — in two halves.**

### Mechanism, confirmed by reading the code rather than by trusting the report

`scripts/lib/proposal_schema.py` deduplicates skill names with
`_need(len(names) == len(set(names)), "duplicate skill names")` — an exact-string comparison.
`alpha` and `ALPHA` pass it. `scripts/persist-proposal.py::_plan` then plans a write to
`skills_dir/<name>/SKILL.md` for each, and `_merge_usage` adds a record per name. On a
case-insensitive filesystem both directories are one entry: the second `SKILL.md` overwrites the
first while `.usage.json` gains two independent records. Exactly the reported behaviour.

### Validating the logic on Linux

Linux is case-sensitive here (`[capability probe] case-insensitive filesystem: UNAVAILABLE`), so
the collision cannot be reproduced directly. Two things made it verifiable anyway:

1. **The in-proposal half needs no filesystem at all.** It is caught in `validate_proposal`, so
   its five new tests in `tests/test-proposal-schema.py` are meaningful on every runner —
   strictly better than the old shape, which could only be exercised on the two cells that
   reproduce the fold.
2. **The cross-review half was written as a pure function** so the decision logic is testable
   anywhere: `_folds_onto_other_entry(name, entry_exists, actual_entries)`. All four quadrants are
   asserted directly, plus a purity check.

### Chosen behaviour, and why

**Refuse. Not merge, not rename.** Merging would join two skills the reviewer meant to keep
apart. Renaming to the on-disk casing would silently rewrite the user's store — precisely what
this module's threat model forbids. Refusing writes nothing at all, so no existing store is
touched.

- **Within one proposal** — rejected **unconditionally**, not gated on a filesystem probe. Two
  names differing only in case in a single proposal is incoherent intent on any filesystem, and
  there is none on which accepting both is obviously right. It also means a store written on
  Linux is not corrupt the moment it is synced to macOS.
- **Across reviews** (`alpha` persisted earlier, `ALPHA` proposed later) — handled in `_plan` by
  an **observation**, not a probe file and not a platform-name branch:
  `(skills_dir / name).exists() and name not in os.listdir(skills_dir)`. On a case-sensitive
  filesystem the path simply does not exist, so it cannot false-positive there. It runs inside the
  store lock, so a concurrent writer cannot create the colliding entry between check and write.

**A legitimate re-write of the same skill is never refused** — the exact name *is* in the
listing, so the predicate is False. That case has its own end-to-end test
(`test_same_name_rewrite_is_never_refused`), because it is the loop's most common operation and
breaking it would be worse than the defect.

**Loudness.** Both refusals are non-zero exits (1 from validation, 2 from the writer). The
detached pipelines in `session-review.sh` and `copilot-session-review.sh` append a line to
`persist-failures.log` on any non-zero status, and `doctor.sh` surfaces that log. Never a silent
drop. The writer's message names the colliding entries and tells the user what to do.

### The sweep's finding is now an assertion

`tests/test-adversarial-sweep.py::test_case_collision_alpha_ALPHA` no longer calls `finding(...)`
and pass. It asserts exit ∈ {1, 2}, a `case-fold` reason on stderr, and that *nothing* was written
(no `.usage.json`, no skill directory). Because the fix is filesystem-independent, the assertion
holds on all six matrix cells rather than only the two that can reproduce the collision. A second
test, `test_case_variant_of_an_existing_skill_never_destroys_it`, covers the cross-review half and
asserts **both** filesystem outcomes rather than skipping one — with `alpha`'s content asserted
intact on both branches. The one outcome ruled out everywhere is "accepted, and `alpha`'s content
is gone."

### Mutation results — 2 killed, 0 survived

| Mutation | Result |
|---|---|
| Remove the casefold check from `validate_proposal` | **KILLED** — `test-proposal-schema.py`: 3 failures; `test-adversarial-sweep.py`: 2 failures |
| Make `_folds_onto_other_entry` return `False` always | **KILLED** — `test-persist-proposal.py`: 1 failure |
| Restored | OK |

### Only CI can confirm

The *observation* that feeds the cross-review guard — a case-insensitive filesystem reporting
`skills/ALPHA` as existing when only `skills/alpha` was created — cannot be produced on a
case-sensitive filesystem. Only the macOS and Windows cells exercise the refusal path end to end;
there, the sweep probes `case-insensitive filesystem: AVAILABLE` and asserts it for real. On
Linux that branch prints a loud skip naming exactly what was not exercised.

---

## Part B — plan process debt

**Verdict: real, fixed.** `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md`
(1611 → 1724 lines).

Read `plan-vs-delivered-audit.md` first; its §9 "What the plan got wrong" enumerates eight
divergences, and each is now marked **in place** with a `SUPERSEDED` callout naming its successor:

| # | Passage | Superseded by |
|---|---|---|
| 1 | GC4 "paths in exactly one place" | `config.sh`'s python3-less fallback + `doctor.sh`'s print-only re-read; the `LOCALAPPDATA` divergence is named as a residual |
| 2 | GC5 "reviewer must not be granted file-write tools" | Now met on both paths (A1 above) — the callout records that the plan's *own* Task 5 snippet is why it was not |
| 3 | "Unchanged but load-bearing: `hook-input.sh`, `coach-signals.py`" | Both changed |
| 4 | Task 3's `_FENCE_RE` | Linear `str.find` scanner (26.1s → 0.00078s); `^…$` → `\A…\Z` |
| 5 | Task 4's flat `learned-skills/<name>.md` | `<name>/SKILL.md` via `skill_layout.py` — flagged **DO NOT IMPLEMENT**, since copying it reintroduces a Critical |
| 6 | Task 4's `_assert_inside()` | `dir_fd` + `O_NOFOLLOW`, with the Windows residual disclosed |
| 7 | Task 6's "poll for the file" | `.review-complete` marker |
| 8 | Out-of-Scope deferral of session-source adapters / deep security audit | Both built anyway (`transcript.py`, `test-adversarial-sweep.py`) |

Plus a **banner** at the top of the file warning before anyone implements from it, and
**Appendix A** recording rounds P0–P9, A–F, and this closeout — as a pointer table into
`progress.md` and the per-round reports, not a duplicate of them, with `git log` named as the
source of truth over both. Appendix A also carries the known-residuals list.

**Nothing was deleted or rewritten.** The plan is a record of what was agreed; its value is in
showing where reality diverged and why.

---

## Part C — documentation

Every claim re-derived. Findings:

| Claim | Was | Now |
|---|---|---|
| Suite count | `37 as of this writing` in README's structure block; a mixture of 37/41 in CLAUDE.md | No count recorded. Both files state the command and point at `run-all.sh`'s own `Discovered N suite(s)` line |
| CI status / run id | Frozen `30167923350` in three places, with "the four newest suites are unobserved on the matrix" | No run id recorded anywhere. `gh run view 30174843845` confirmed all six cells green at `f7cfe95` (41 suites), so the pessimistic claim was stale — but that is reported as an observation, not written down as a fact |
| Store lock backends | Described correctly | Added: both backends confirmed to **execute** in CI. `test-persist-concurrency.py` prints the backend, and the run log shows `backend=flock` on ubuntu/macos and `backend=msvcrt` on windows. Command to reproduce given |
| Coach coverage 11/45, 34 skipping with named fields | Already accurate and pinned by `EXPECTED_EVALUATED = 11` / `EXPECTED_TOTAL_RULES = 45` | Unchanged; re-verified in the tree |
| `sqlite3` no longer a runtime dependency | Already correct — the requirements table already marked the CLI optional and degrading to a warning | Unchanged; re-verified |
| Python floor | `3.8+` in both files | `3.9+`. **3.8 was an unverified claim**: CI's floor is `["3.9", "3.13"]` and nothing here is ever run on 3.8 |
| Live Copilot check | CLAUDE.md's roadmap row said "still pending manual verification" while its own branch-status block said DONE | **Internal contradiction, found and resolved to DONE** with the residual named |
| Branch status | "six post-implementation fix rounds (A-F)" | A–F **plus P0–P9 plus this closeout**, with pointers to the audit and the annotated plan |
| Requirements / storage / migration / diagnostics | Re-read in full against the tree | Accurate as written; unchanged |

New in README: a **Bounding reviewer cost** section (the two harnesses' different mechanisms and
why the Copilot ceiling is opt-in), the reviewer tool-restriction fact in the compatibility table,
and a **Known residuals** section.

### The `transcript.py` code-not-prose question

The brief asked whether the honest mitigation is code rather than prose, and to validate whether
digestion currently fails loudly or silently.

**Validated: it already fails loudly. No code change was needed, and none was made.**

`build_copilot_session_digest` and `build_claude_session_digest` return a `(digest,
failure_reason)` pair in which exactly one is non-empty, covering every degraded outcome:

- `"unavailable (no sessionId in sessionEnd payload)"` / `"unavailable (no transcript_path …)"`
- `"unavailable (events.jsonl not found under …)"` / `"unavailable (transcript file not found …)"`
- `"empty (0 parseable events in …)"` — a vendor switching away from JSONL entirely
- `"has no user/assistant messages (N other event(s) in …)"` — **the exact signature of a renamed
  schema**: lines still parse, but none match the expected event shape

`main()` passes any non-empty reason to `_log_failure`, and **both** review scripts invoke it with
`--log-file "${SL_LOG_DIR}/persist-failures.log"` (verified: `session-review.sh:66`,
`copilot-session-review.sh:33`), which `doctor.sh` surfaces. The signature failure mode — a review
that runs, exits 0, and silently yields an empty transcript — is already closed. This is recorded
as a residual in prose because a format change cannot be made *impossible*, only impossible to
hide; that distinction is now stated explicitly in README's Known residuals.

**This is a "validated, not real, so not changed" outcome**, and per the governing instruction
that is the better result than a plausible-looking change.

---

## Nothing needing a decision from the user

One thing worth flagging rather than deciding unilaterally, since it is a judgement call and not
a defect: `SL_COPILOT_MAX_AI_CREDITS` defaults to **off**. If the user would rather trade
compatibility with older `copilot` builds for a default ceiling, flipping the default to `30` is a
one-line change in `scripts/lib/config.sh` and the tests already cover that state. The reasoning
for the current default is in A2 above and in the file itself.

## Corrections to the brief

Recorded because the brief invited them:

1. **A2's premise was wrong.** `--max-ai-credits` does exist in the installed `copilot` 1.0.75,
   documented under `copilot help limits` with a minimum of 30. The earlier round's enumeration
   missed it.
2. **The `transcript.py` silent-failure concern in Part C was not real.** It already fails loudly
   into `persist-failures.log` on every degraded path, including the renamed-schema case.
3. **The README/CLAUDE.md CI claims were stale in the *pessimistic* direction** — they said the
   four newest suites were unobserved on the matrix; run `30174843845` had in fact run all 41 on
   all six cells, green. The pattern this session has been over-claiming; this one was
   under-claiming.
