# Fix P1/P2 report — codified adversarial sweep + Windows capability probes

Closes the two biggest remaining verification gaps on `harness-neutral-persistence`:
the reviewer's ad-hoc adversarial sweep against the persist-proposal trust
boundary was never checked in, and the Windows symlink/hardlink test skips
were inferred from the platform name rather than measured. Both are now
codified, permanent, and CI-enforced.

## TASK 1 — `tests/test-adversarial-sweep.py`

New suite, 32 test methods, **95 individual attacks executed** on this
runner (floor: 55 — set generously below the true ~66-attack inventory so
legitimate platform-driven skips can never trip it, while an import failure
or a suite that silently ran nothing still would). Runtime: ~1s. Discovered
by `tests/run-all.sh`'s existing glob with no changes needed there; suite
count is now 31 (was 30).

### Attack inventory and counts

| Layer | Attacks | Notes |
|---|---|---|
| Schema (name/filename allow-list) | 29 names × 2 fields = 58 | Every name tested as both a skill `name` and a memory `file` value |
| Resource exhaustion | 5 | 400KB bracket bomb, 100k-deep nesting, 100k fence openers, unterminated fence, the 872KB ReDoS regression pin |
| Filesystem | 23 | See list below |
| Confinement backstop (bypasses schema) | 8 | Calls `_plan`/`_write_all` directly with raw names |
| TOCTOU | 1 (40 inner iterations) | Symlink-swap race against a live writer run |

Filesystem-layer attacks, matching the assigned list: symlinked skill dir →
outside; symlinked `skills_dir` root → outside; symlinked `skills_dir` →
inside store; symlinked `memory_dir` → outside; symlink at
`<name>/SKILL.md` → canary; hardlink at `<name>/SKILL.md`; symlink at
`.usage.json` → outside; hardlink at `.usage.json`; `<name>` pre-exists as a
regular file; `<name>/SKILL.md` pre-exists as a directory; dangling symlink
at `<name>`; pre-existing legacy flat `<name>.md` preserved; read-only
`skills_dir`; read-only store root; corrupt `.usage.json`; `.usage.json` as
a JSON array; NUL in content (end-to-end); all-or-nothing ×3 (symlinked
skill / bad skill name / corrupt `.usage.json`); no `.persist-tmp-*`
leftovers after failure; case collision `alpha`/`ALPHA`; mode 0600 on
success.

Every capability the suite depends on (symlink creation, hardlink creation,
`O_NOFOLLOW`, chmod-enforced read-only, case-insensitive filesystem) is
**measured at import time**, printed to stderr unconditionally
(`[capability probe] ...`), and a skip caused by an unavailable capability
prints `[SKIPPED ATTACK] <name>: <reason>` in addition to unittest's own
skip bookkeeping — never a silent absence. On this Linux runner all
capabilities were available except case-insensitivity (expected).

### Key result: two attacks behaved differently than the original sweep reported

The task brief was explicit that this is the result that matters most,
since the original "zero issues" sweep predates three modifications to
`persist-proposal.py`. Two did:

**1. Confinement-backstop escape via `_plan`/`_write_all`'s mkdir-before-check ordering (fixed).**
Calling `_plan`/`_write_all` directly with a raw skill name of `"/tmp/evilpwn"`
(schema-unreachable, since `SKILL_NAME_RE` forbids `/` — this is exactly
what the confinement backstop exists to test) created a real, empty
directory at `/tmp/evilpwn` on disk before `_write_all`'s confinement check
ever fired and refused the write. Root cause: `directory.mkdir(parents=True,
exist_ok=True)` ran *before* `_assert_inside(parent, directory)` in the
per-directory loop in `_write_all`. Python's `pathlib` `/` operator silently
discards the left operand when the right operand looks absolute, so
`skills_dir / "/tmp/evilpwn"` (constructed during `_plan`) is simply
`Path("/tmp/evilpwn")` — nothing about it is anchored under the store by
that point. Confirmed by direct reproduction before fixing (see commit),
then fixed by reordering the loop in `_write_all` (scripts/persist-proposal.py):
the confinement/symlink check for a directory now runs *before* `mkdir`,
not after, for every level beyond the first. Content was never written in
either case — the schema already blocks this path entirely in normal
operation — but a stray directory outside the store is a real artifact an
attacker with `_plan`/`_write_all`-level access (a bug elsewhere, a future
refactor) could have produced. Verified no regression: all 22
`test-persist-proposal.py` tests and 53 `test-proposal-schema.py` tests
still pass; the confinement backstop's 8 raw names now leave zero paths
outside the store dir in all cases (previously 1/8 did).

**2. TOCTOU symlink-swap race: measured 4/40 (10%) escapes, not "0/40" (not fixed — documented, reported, bounded).**
Running the race for real (a thread continuously swapping
`learned-skills/alpha` between a real directory and a symlink to an
`outside/` directory, while `_plan`/`_write_all` runs concurrently) measured
a **10% escape rate** under active contention — four of forty iterations
landed real content (`pwned`) inside `outside/`, two of those with a fully
successful writer exit (no error at all). This is a real, previously
unmeasured instance of a residual `persist-proposal.py`'s own docstring
already names: *"a narrower, un-closed residual also lives between
`_assert_inside(root, ...)` above and `tempfile.mkstemp(dir=root)` inside
`_stage`... Closing it would need `dir_fd`-relative operations throughout,
and `mkstemp` has no `dir_fd` parameter to hang that off of. Documented, not
fixed."* The prior ad-hoc sweep reported "40 iterations, 0 escapes" for
this same attack; this codified run does not reproduce that — it measures a
non-trivial, repeatable escape rate.

**Disposition**: not fixed in this pass. A real fix needs `dir_fd`-pinned
file operations end-to-end (`os.open`/`os.mkdir`/`os.replace` with
`dir_fd=`, all POSIX-only — `os.supports_dir_fd` excludes Windows for these
calls, so it would also need a documented, probed fallback there), which is
a materially larger, cross-platform-sensitive change than either of the two
verification gaps this pass was scoped to close, and the code's own
docstring already shows this was a conscious, considered deferral rather
than an oversight. The test (`TestTOCTOU`) measures and prints the rate on
every run (`[TOCTOU] N/40 (X%) iterations escaped...`), records it as a
`[FINDING]`, and only fails the suite past a 50% ceiling — high enough that
the known ~10% residual doesn't block CI/merge, low enough that a total
confinement collapse (verified via mutation testing below — see mutation 2)
still fails loudly. **This is a real, open risk the branch owner should
decide how to handle** (accept as documented residual, or schedule the
`dir_fd` rearchitecture as follow-up work) — it is not swept under the rug
by this suite; it prints on every CI run.

Also confirmed one already-documented **non-issue**: the redundant
directory-level `_reject_if_symlink` call in `_write_all`'s per-directory
loop (mutation 3, below) really is redundant exactly as the code's own
docstring claims — removing it did not open any new escape in the
filesystem/confinement/all-or-nothing tests (the two surrounding checks,
`_assert_inside`'s implicit symlink check on `root` and the final
`_assert_inside(stage_dir, target)`'s implicit check on `stage_dir`, still
close it) — though it did raise the TOCTOU race's measured escape rate from
10% to 20%, consistent with removing one of several redundant checks along
the same narrow window.

### Mutation testing (verifies the suite can actually fail)

Five mutations applied one at a time to the real files, suite re-run, then
reverted (confirmed via `diff` against saved originals — clean both times):

| # | Mutation | File | Result | Attacks that caught it |
|---|---|---|---|---|
| 1 | Remove Windows-reserved-name check | `proposal_schema.py` | **KILLED** | 4 schema-layer subtests (`CON`, `con`, `COM1`, `nul` as skill name) |
| 2 | Remove parent-containment check in `_assert_inside` | `persist-proposal.py` | **KILLED** | 4 confinement-backstop subtests (`../../evil`, `/tmp/evilpwn`, `.`, `""`) |
| 3 | Remove the per-directory `_reject_if_symlink` call in `_write_all` | `persist-proposal.py` | **SURVIVED** — but this matches the code's own documented claim that this specific check is redundant (see "already-documented non-issue" above); no attack in this suite treats it as a live protection, so nothing here is decorative | — (TOCTOU rate rose 10%→20%, still caught by the 50% ceiling if it had gone further) |
| 4 | Weaken `SKILL_NAME_RE` to `.{1,64}` (drop charset restriction) | `proposal_schema.py` | **KILLED** | 25 schema-layer subtests |
| 5 | Remove the NUL-byte content check | `proposal_schema.py` | **KILLED** | 1 (`fs:nul-in-content-end-to-end`) |

4 of 5 mutations were killed outright by attacks already in the suite. The
one survivor (mutation 3) is the one case the writer's own docstring already
predicted would be redundant — verified, not assumed — so no attack here is
decorative in the sense the task asked to guard against.

## TASK 2 — Windows capability probes, not platform-name assumptions

`tests/test-persist-proposal.py`: all 7 `sys.platform.startswith("win")`
skips replaced with real capability probes, run once at import time and
printed unconditionally to stderr:

```
[capability probe] symlink creation: AVAILABLE|UNAVAILABLE (probed, not platform-assumed)
[capability probe] hardlink creation: AVAILABLE|UNAVAILABLE (probed, not platform-assumed)
[capability probe] O_NOFOLLOW: AVAILABLE|UNAVAILABLE (POSIX-only primitive)
```

- `_can_symlink()` / `_can_hardlink()`: attempt a real symlink/hardlink in a
  temp dir; skip only if the attempt genuinely raises `OSError`. Mirrors
  `tests/test-path-compare-lib.sh`'s `[[ -L ]]` probe after `ln -s` and
  `tests/test-doctor.sh`'s real write attempt after `chmod 500`.
- `HAS_O_NOFOLLOW`: `getattr(os, "O_NOFOLLOW", 0) != 0`. This one **is**
  legitimately a structural platform fact rather than something to probe by
  action (the attribute is simply absent from `os` on native Windows), so
  attribute-presence is the correct check here, not an unprobed assumption.
- Each of the 7 skip sites now states precisely what was probed and found
  unavailable (e.g. `"symlink creation probed and unavailable on this
  runner"`), never `"...on Windows"`.
- `test_open_nofollow_fd_rejects_symlink` needs both `O_NOFOLLOW` (the
  behavior under test) and symlink creation (to construct the fixture); both
  probes are checked, each with its own accurate skip message.
- `test_read_existing_rejects_symlink_even_without_o_nofollow` only needs
  symlink creation (it monkeypatches `O_NOFOLLOW` away itself to simulate
  its absence) — its skip reason was corrected from "this test simulates
  Windows by removing O_NOFOLLOW" (which was actually describing why the
  test exists, not the skip condition) to state plainly that it needs a real
  symlink to construct the fixture.

All 22 tests pass on this Linux runner with all three probes reporting
`AVAILABLE`; the `test-adversarial-sweep.py` suite added in Task 1 applies
the identical probing discipline independently (its own `CAN_SYMLINK` /
`CAN_HARDLINK` / `HAS_O_NOFOLLOW`, plus `READONLY_ENFORCED` and
`CASE_INSENSITIVE_FS` for the attacks that need them) rather than importing
from this file, so the two suites' probes are cross-checkable against each
other in CI output rather than depending on one shared, possibly-wrong
answer.

**What only CI can answer**: whether `windows-latest` in GitHub Actions can
actually create symlinks/hardlinks. This was not knowable from this Linux
sandbox and was not guessed at — the probe design means the *next* CI run's
`[capability probe]` lines in the Windows job's log say directly whether the
7 previously-Windows-skipped tests (and the equivalent attacks in the new
adversarial suite) ran for real there, or were skipped with an accurate,
loud, probed reason. If `windows-latest` turns out to allow symlink
creation (plausible — the runner user is frequently administrator-equivalent
or Developer Mode is enabled), this alone converts up to 7 + several
adversarial-suite attacks from "never exercised on Windows" to "exercised
on Windows," with no code change needed beyond what's in this commit.

## Files changed

- `tests/test-adversarial-sweep.py` (new) — the codified sweep.
- `scripts/persist-proposal.py` — reordered the per-directory confinement
  check in `_write_all` to run before `mkdir` rather than after, closing
  the stray-directory-outside-store artifact found by the confinement
  backstop (finding #1 above).
- `tests/test-persist-proposal.py` — 7 platform-name skips replaced with
  capability probes; probe results printed unconditionally.
- This report.

## Verification run

```
$ bash tests/run-all.sh
Discovered 31 suite(s): 23 shell, 8 python. Ran 31.
All 31 suites passed.

$ ~/.pyenv/versions/3.9.24/bin/python3.9 tests/test-adversarial-sweep.py
...OK (95 attacks executed, floor 55)

$ ~/.pyenv/versions/3.9.24/bin/python3.9 tests/test-persist-proposal.py
...OK (22 tests)
```

## Does the current writer still repel every attack?

**Almost, with one open, measured, non-blocking exception.** Every schema,
resource-exhaustion, filesystem, and confinement-backstop attack is repelled
(58 + 5 + 23 + 8 = 94 of the 95 attacks executed here pass cleanly). The one
exception is the TOCTOU symlink-swap race: a genuine, previously-unmeasured
~10% escape rate against a residual the code's own docstring already
disclosed but had never actually been run to find a number for. It is not
fixed in this pass (scope: `dir_fd`-pinned rearchitecture, POSIX-only,
cross-platform-sensitive) but it is no longer a silent unknown — it prints
on every CI run and is bounded so it cannot silently regress further without
tripping a 50% ceiling.
