# Fix round B report — skill persistence contract

Branch: `harness-neutral-persistence`. Builds on round A (`6316e4f`).

## What changed and why

### C4 — skills persisted into a layout nothing reads

`scripts/persist-proposal.py` wrote `skills_dir/<name>.md` (a flat file). Every
consumer (`inject-agents-md.py`, `curator-run.sh`, `skill-lifecycle.py`)
requires `skills_dir/<name>/SKILL.md` (a directory) plus an entry in a shared
`skills_dir/.usage.json`. The writer and its consumers had disagreed about the
on-disk contract since Task 4; each was correct against its own brief.

Fix, treating the consumers as authoritative (they predate the writer):

1. `_plan()` now targets `skill_dir / "SKILL.md"` where `skill_dir =
   skills_dir / entry["name"]`, instead of `skills_dir / f"{name}.md"`.
2. `_plan()` also reads the existing `.usage.json` (via the same
   symlink/hardlink/UTF-8-safe `_read_existing` used for append-mode memory
   files), merges in a create-or-refresh record per skill in the proposal,
   and appends that merged content as one more planned write targeting
   `skills_dir/.usage.json`. Because it's just one more entry in the same
   `planned` list that `_write_all()` stages-then-renames, the SKILL.md
   content and its `.usage.json` record land in the exact same
   staged-then-renamed transaction — a crash between them is not possible
   (only a crash *during* the final rename loop, the pre-existing residual
   risk this module already documents for cross-file atomicity).
3. Both reviewer prompts (`session-review.sh`, `copilot-session-review.sh`)
   corrected: removed "Set created_by=\"agent\" in .usage.json for any new
   skill" (the reviewer never writes files — this was a leftover instruction
   from before the writer inversion) and reworded the skill-review step to
   say the *writer* persists to `<skill-name>/SKILL.md` and refreshes
   `.usage.json` automatically.

### `.usage.json` schema — how I confirmed it, not invented

Read from three independent consumers, all agreeing:
- `scripts/skill-lifecycle.py`: single shared file at `SKILLS_DIR/.usage.json`,
  a dict keyed by skill name. Fields read: `created_by`, `state`, `pinned`,
  `use_count`, and the activity fields `last_used_at`/`last_viewed_at`/
  `last_patched_at`/`created_at` (first non-null wins, in that priority
  order, via `compute_activity_anchor`).
- `scripts/curator-run.sh`: reads the same shared file with `jq -r
  'keys[]'`, `.[$n].state`, `.[$n].pinned`, `.[$n].use_count`.
- `tests/test-skill-lifecycle.sh`'s `write_fixture()`: an existing, already
  round-A-tested fixture with exactly this shape (`created_by`, `state`,
  `pinned`, `use_count`, `last_used_at`).

New-skill records set only fields these consumers actually read:
`created_by="agent"`, `created_at=<now>`, `state="active"`, `pinned=false`,
`use_count=0`, and always bump `last_patched_at=<now>` — chosen because its
name is exactly "content was patched," which is what a persist write is.
Refreshing an *existing* record only sets missing fields via `setdefault`
and always bumps `last_patched_at`; it never clobbers a human's `pinned`,
the lifecycle's `state`, or accumulated `use_count`.

### I8 — prompt/schema charset disagreement

`proposal_schema.py`'s `SKILL_NAME_RE` (`[A-Za-z0-9][A-Za-z0-9_-]{0,63}`, no
dots) was kept as-is — the conservative choice, since dots interact badly
with the new per-skill directory (`.`/`..`, leading-dot hidden dirs,
`.usage.json` name collision at the schema layer). Both prompts previously
stated the regex twice, contradicting themselves 6 lines apart
(`^[a-z0-9][a-z0-9._-]*$` early, the real regex later in the OUTPUT
CONTRACT). Both now state the real regex exactly once, matching the schema.
Regression tests grep the prompt files directly for the stale dot-inclusive
pattern (`tests/test-session-review.sh`, `tests/test-copilot-session-review.sh`).

A single bad skill name discarding valid memory entries in the same proposal
was already handled correctly before this round: `session-review.sh` and
`copilot-session-review.sh`'s background pipeline already append to
`persist-failures.log` on any non-zero exit from `persist-proposal.py |
python3 persist-proposal.py`. Verified end-to-end in
`tests/test-e2e-skill-visibility.sh` (step 5): a dotted skill name plus valid
memory produces no MEMORY.md and a populated `persist-failures.log`.

### New finding from round A — `inject-agents-md.py`'s hardcoded fallback

`inject-agents-md.py:100-102` fell back to `Path.home() / ".claude" /
"memory"` / `"learned-skills"` when `SL_MEMORY_DIR`/`SL_SKILLS_DIR` were
unset, instead of consulting `lib/paths.py`. Fixed the same way round A fixed
`skill-lifecycle.py`: a `_default_dir(env_var, paths_key)` helper that checks
the env var first, else `paths.resolve_all()[paths_key]`. Fixed **both**
`SL_MEMORY_DIR` and `SL_SKILLS_DIR` (the finding named only the skills line,
but the memory line is the identical bug in the same file, and the global
constraint — no `~/.claude` on any Copilot/VS Code code path — applies to
both). Verified no `~/.claude` is ever created when neither env var is set
and only `AGENT_LEARNING_HOME` points elsewhere (new test case 5 in
`tests/test-inject-agents-md.sh`).

## End-to-end test (`tests/test-e2e-skill-visibility.sh`) — the deliverable

Drives the real pipeline: a fake `copilot` shim (same pattern as the existing
`test-copilot-session-review.sh`) emits a fenced-JSON proposal with one memory
entry and one skill → the real `copilot-session-review.sh` → the real
`persist-proposal.py`, all against a sandboxed `AGENT_LEARNING_HOME`. Then:

1. Asserts the skill landed as `<name>/SKILL.md`, not the old flat file, and
   that `.usage.json` got a `created_by=agent` entry.
2. Runs the real `inject-agents-md.py` against the store the pipeline just
   populated and asserts the just-persisted skill's name *and* description
   appear in the managed `AGENTS.md` block — the exact assertion whose
   absence let C4 ship (the final review's own repro: a Copilot-path skill
   was written, then invisible to `inject-agents-md.py`'s output).
3. Repeats the AGENTS.md check via `lib/paths.py`'s own default resolution
   (no env override), covering an unconfigured real install, not just the
   env-var override path.
4. Runs the real `skill-lifecycle.py --dry-run` (invoked the way
   `curator-run.sh` invokes it: `SL_SKILLS_DIR` set, no arguments) and
   asserts it reports `checked=1` rather than "Nothing to do" — proving the
   curator/lifecycle blindness is closed too, not just the AGENTS.md path.
5. Drives the pipeline a second time with a dotted skill name and asserts
   both that memory is *not* persisted and that `persist-failures.log` gets
   a trace (the I8 all-or-nothing-with-visibility check).

All 12 assertions in this suite pass.

## Security re-run against the new directory-creating code

Ran the same attack classes named in the brief against the new code
(scripts in `/tmp/security_repro.py`, `/tmp/security_repro_fs.py` during this
session — not committed, throwaway repro scripts):

**Schema-level (unchanged, still enforced):** traversal (`../evil`),
absolute path (`/etc/passwd`), backslash separator, Windows reserved names
(`CON`, `con`), NUL byte in name, NUL byte in content, homoglyph character
(Cyrillic а), ADS-style colon (`alpha:stream`) — all rejected, exit 1.

**Filesystem-level, against the new per-skill *directory* code specifically:**
- Symlinked skill directory (`skills_dir/evil -> outside`) — refused, exit 2,
  `outside/` untouched.
- Symlinked `skills_dir` root itself — refused, exit 2, target untouched.
- Hardlinked `SKILL.md` (pointing at a file outside the store) — original
  content preserved (`os.replace` never follows a symlink/repoints a
  hardlink's directory entry, not its content).
- Read-only `skills_dir` — refused with exit 2, no traceback, no partial
  write.
- `SKILL.md` pre-existing as a directory — refused, exit 2.
- New `SKILL.md` and `.usage.json` both land at mode 0600.
- All-or-nothing preserved: valid memory + a skill-directory symlink attack
  in the same proposal writes *nothing*, including the memory entry.

No regression found. The new directory level got the same confinement,
symlink, and mode-0600 guarantees as the flat-file path had.

## Existing tests that encoded the bug, and how they were corrected

- `tests/test-persist-proposal.py::test_writes_memory_and_skill` asserted
  `(home / "learned-skills" / "alpha.md")` — the flat-file layout itself.
  Corrected to assert `alpha/SKILL.md` exists and `alpha.md` does not. This
  is a legitimate correction of a test that was pinning the bug, not a
  weakening — it now also asserts `.usage.json` gets a `created_by=agent`
  entry.
- `tests/test-persist-proposal.py::test_directory_collision_on_second_entry_leaves_first_uncommitted`
  fixtured a pre-existing directory at `learned-skills/beta.md` to force a
  collision. Under the new layout that path no longer collides with
  anything (the real target is `beta/SKILL.md`). Rewrote the fixture to put
  the directory at `beta/SKILL.md` instead — same intent (force the
  "target pre-exists as a directory" failure mode), correct path for the
  new contract.

## Mutation testing (killed/survived)

| Fix | Mutation | Result |
|---|---|---|
| Directory layout for skills | Reverted skill target to flat `<name>.md` | **Killed** — 5 unit test failures + 5 e2e assertion failures |
| `inject-agents-md.py` paths.py fallback | Reverted to hardcoded `~/.claude/...` | **Killed** — 2 new fallback-test failures |
| `.usage.json` create-or-refresh preserving existing fields | Unconditional overwrite instead of `setdefault` | **Killed** — refresh test failed (`created_at` clobbered) |
| Per-directory-level explicit symlink check in `_write_all` | Deleted the explicit `_reject_if_symlink(directory, ...)` inside the mkdir loop | **Survived** — see below |
| Prompt regex consistency | Reverted `session-review.sh`'s corrected regex line back to the dot-inclusive form | **Killed** — new grep-based prompt-consistency test failed |

The one survived mutation is not a real gap: at the current chain depth (max
2 levels, `skills_dir -> skill_dir`), the property is independently covered
twice more — the *next* loop iteration's `_assert_inside(parent, directory)`
symlink-checks `parent`, and the post-loop `_assert_inside(stage_dir,
target)` symlink-checks `stage_dir`. Verified both by re-running
`test_symlinked_skill_directory_is_refused` with only that one line removed
(still passed) — full reasoning and the mutation result are now recorded
directly in `_write_all`'s docstring rather than left as an undocumented
redundancy. Kept the explicit check anyway: it is what would keep a future
third chain level safe without relying on being some other directory's
`root` argument on a different iteration.

## Pre-existing flat-file skills — decision

**Leave and document** (chosen over adding read-compatibility). Round A/B
scope explicitly forbids deleting existing user data, and this module never
overwrites a `<name>.md` flat file with a same-named `<name>/` directory
write — they're different paths, so both can coexist without collision.
`inject-agents-md.py` does not list flat-file skills (only directories with a
`SKILL.md` inside) — this is pre-existing behavior, not a regression from
this round: before this fix, *no* consumer read anything the writer produced
for skills, flat or otherwise. `skill-lifecycle.py` and `curator-run.sh`
likewise only ever act on names present in `.usage.json`, which the old
writer never populated, so a legacy flat-file skill was never eligible for
(and cannot now be accidentally caught by) any lifecycle transition. No
auto-migration was added; this is called out here as a known, deliberate gap
rather than fixed, to keep this round's diff scoped to the C4/I8 contract.

## New instance of the exit-0-while-wrong pattern (reported, not fixed)

None found beyond what the brief already named. One adjacent observation
worth flagging for round C: `curator-run.sh`'s `TRANSITION_LOG` check (`if
[[ -z "$TRANSITION_LOG" ]]`) treats an *empty* `skill-lifecycle.py` stdout as
"no transitions" and appends "_No transitions this cycle._" to the report —
but `skill-lifecycle.py` always prints at least a non-empty summary line
(`\nLifecycle summary: checked=...`), so this branch appears currently
unreachable in practice (not verified further; out of this round's scope,
flagging only).

## Test suite

`bash tests/run-all.sh`: **22 suites** (17 shell, 5 Python) — up from the
round-A baseline of 21 (added `tests/test-e2e-skill-visibility.sh`). All
pass.

## Files changed

- `scripts/persist-proposal.py` — directory-per-skill write, `.usage.json`
  create-or-refresh in the same transaction, per-level directory
  confinement/symlink checks.
- `scripts/inject-agents-md.py` — `paths.py`-backed fallback for both
  `SL_MEMORY_DIR` and `SL_SKILLS_DIR`.
- `scripts/session-review.sh`, `scripts/copilot-session-review.sh` —
  reviewer prompts corrected to match the writer's actual contract and the
  schema's actual skill-name regex.
- `tests/test-persist-proposal.py` — flat-file assertions corrected to the
  directory layout; new tests for `.usage.json` creation/refresh,
  transactional atomicity, the new symlinked-directory attack surface, and
  the I8 dotted-name-discards-memory scenario.
- `tests/test-inject-agents-md.sh` — new fallback-resolution regression test.
- `tests/test-session-review.sh`, `tests/test-copilot-session-review.sh` —
  new prompt-consistency regression checks.
- `tests/test-e2e-skill-visibility.sh` (new) — the end-to-end deliverable
  described above.
