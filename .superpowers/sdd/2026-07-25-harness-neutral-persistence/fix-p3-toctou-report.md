# Fix P3: TOCTOU escape in persist-proposal.py's write path

**Date**: 2026-07-25
**Scope**: `scripts/persist-proposal.py`'s trust boundary — a documented, measured symlink-swap
race between the last confinement check on a skill directory and the temp-file write that
follows it.

## 1. What actually escapes: content, not just directories

**Determination: file content escapes, not empty directories.**

Method: instrumented the attack in `tests/test-adversarial-sweep.py`'s `TestTOCTOU` (a thread
continuously swapping `<skills_dir>/alpha` between a real directory and a symlink pointing
outside the store, while `_write_all(_plan(...))` runs for a skill named `alpha`) against the
pre-fix writer, and inspected exactly what landed in the `outside` directory across two
independent 300-iteration runs.

| Run | Iterations | Escapes | SKILL.md (final content) | .persist-tmp-* (staged content) | Empty directory only |
|---|---|---|---|---|---|
| A | 300 | 44 (14.7%) | — (not separately classified) | — | 0 |
| B | 300 | 22 (7.3%) | 2 | 20 | 0 |

Zero escapes, in either run, were an empty directory with no file inside it. Every escape that
occurred put a real file — either the fully-committed `SKILL.md` (the actual proposal content,
`"pwned"` in the harness) or a still-staged `.persist-tmp-*` file already carrying that same
content — directly inside the attacker-controlled `outside` directory. This happens because once
`skill_dir` is a symlink to `outside`, both `tempfile.mkstemp(dir=skill_dir)` (staging) and
`os.replace(tmp, target)` (commit) resolve through that symlink transparently — they write to
wherever the symlink points, exactly as documented risk predicted.

**This is the more severe of the two possibilities named in the task brief: an
arbitrary-write-as-user primitive, not merely a confinement leak of empty directories.**

## 2. Threat model judgement

The attacker able to exploit this must already be a local process capable of creating/replacing
paths inside `<skills_dir>/<skill-name>` while a review is running — i.e. they already have write
access to the store. The escalation this bug grants them is narrow but real: it lets them
redirect *where* the reviewer's write lands, at the user's privileges, to any path they choose
(subject to normal filesystem permissions) instead of only inside the store. That's a
confused-deputy escalation from "can write inside the store" to "can write anywhere the user
can" — worse than the starting position, not catastrophic, and not remotely exploitable (the
reviewing agent itself has no write tool and only emits JSON on stdout; it cannot mount this
attack itself). Judged real and worth fixing, not overstated as remote-exploitable and not
dismissed as cosmetic.

## 3. Design

`scripts/persist-proposal.py` now has two write-phase implementations, dispatched by a real
functional capability probe:

- **`DIR_FD_SUPPORTED`** (`_probe_dir_fd_support`): performs a real, disposable
  `open/mkdir/stat/replace/unlink` sequence with `dir_fd` in a throwaway temp directory at
  import time. This is **not** a platform-name check, and deliberately **not** a bare
  `os.supports_dir_fd` set-membership lookup either: on this project's own Linux dev/CI host,
  `os.replace in os.supports_dir_fd` is `False` (only `os.rename` is listed, even though both
  wrap the same syscall), while `os.replace(..., src_dir_fd=..., dst_dir_fd=...)` demonstrably
  works. Trusting the set literally would have wrongly reported dir_fd unsupported everywhere
  this module runs and silently kept the vulnerable path-based writer active on every POSIX
  platform — exactly the "measured wrong, believed for years" mistake §5 corrects for the prior
  escape-rate claim.

- **`_write_all_fd`** (used when `DIR_FD_SUPPORTED`): every directory below the trusted store
  root (`memory_dir`/`skills_dir` themselves — resolved by `paths.py`, never proposal-derived,
  so opened by path) is opened relative to its parent's already-open file descriptor with
  `O_NOFOLLOW` (`_mkdir_and_open_dir_fd`): create-if-missing via `os.mkdir(name, dir_fd=...)`,
  then a verifying `os.open(name, O_DIRECTORY|O_NOFOLLOW, dir_fd=...)`. Because the *final* open
  that hands back a usable fd always carries `O_NOFOLLOW` and always happens last, there is no
  window where a symlink swapped in between checks goes unchecked — the kernel resolves `name`
  against the fd atomically inside that one syscall. From there, the target is stat'd
  (`os.stat(name, dir_fd=stage_fd, follow_symlinks=False)`), read for append mode
  (`_read_existing_fd`), staged (`_stage_fd` — a from-scratch `O_CREAT|O_EXCL` temp-file
  reimplementation since `tempfile.mkstemp` has no `dir_fd` parameter), and finally committed
  (`os.replace(tmp, target.name, src_dir_fd=stage_fd, dst_dir_fd=stage_fd)`) — all anchored to
  the same fd, never a re-resolved path string.

  Structural (non-filesystem, therefore non-racy) checks — `directory.parent != dirs[i-1]` and a
  suspicious-component check (`""`, `"."`, `".."`, embedded `/` or `\`) — replace `_assert_inside`'s
  `resolve()`-based parent comparison for the attacker-influenced levels (e.g. a skill name),
  since `.name` alone loses information a raw name like `"/tmp/evilpwn"` or `".."` would otherwise
  smuggle past a fd-relative open. The trusted root level keeps the old path-based
  mkdir+symlink-reject+open (with the final `O_NOFOLLOW` open still atomic against anything that
  swaps it in the gap).

- **`_write_all_path`** (used when not `DIR_FD_SUPPORTED`, i.e. currently only native Windows,
  which has no dir_fd support in the stdlib `os` module at all — `os.mkdir(..., dir_fd=...)` etc.
  raise `NotImplementedError` there): unchanged from the prior implementation, docstring updated
  to disclose the residual explicitly rather than claim it fixed.

- **`doctor.sh`** now has a "2b. dir_fd (TOCTOU) support" section that probes and reports
  `ACTIVE` / `NOT AVAILABLE` for the running platform, so an operator does not have to read
  source to learn whether the residual applies to their install.

Every fd this module opens is closed in a `finally` on every path, success or exception,
including partial failures mid directory-walk (`opened_this_entry` closed inline on error before
the exception propagates) — see §6 for the leak check.

## 4. Before/after escape rates

| Condition | Iterations | Escapes | Rate |
|---|---|---|---|
| Pre-fix (path-based writer, standalone harness, run A) | 300 | 44 | 14.7% |
| Pre-fix (path-based writer, standalone harness, run B, content-classified) | 300 | 22 | 7.3% |
| Pre-fix, reported by this pass's codified `TestTOCTOU` before the fix landed | 40 | 5 | 12% |
| **Post-fix (dir_fd writer, standalone harness)** | **300** | **0** | **0%** |
| Post-fix, codified `TestTOCTOU` (now zero-tolerance when `DIR_FD_SUPPORTED`) | 40 | 0 | 0% |
| Mutation (DIR_FD_SUPPORTED forced False, standalone harness) | 300 | 46 | 15.3% |

0/300 on POSIX (this Linux dev host) at an iteration count 5x higher than the task's 60 and
7.5x the suite's default 40. **Target of 0 escapes reached on this platform.** No claim is made
about other POSIX platforms (e.g. macOS) not tested here; `os.supports_dir_fd`/the functional
probe should behave equivalently there since dir_fd is a POSIX primitive, but this was not run
on macOS as part of this pass.

## 5. Correcting the record

`.superpowers/sdd/2026-07-25-harness-neutral-persistence/progress.md` contained: *"40-iteration
TOCTOU race swapping `<name>` between dir and symlink — 0/40 escapes."* That figure was wrong —
not reproduced by either the codified suite (~10-12%/40) or an independent from-scratch
harness (18.3%/60, this pass's own 14.7%/300 and 7.3%/300). A correction has been appended to
that file (dated, not edited in place) explaining the wrong number, the corrected pre-fix rates,
the content-vs-directory determination, and the post-fix rates. See that file's tail for the
full text.

## 6. Mutation testing

Reverted the dispatcher to the path-based writer by forcing `DIR_FD_SUPPORTED = False` at
runtime (without touching any file) and re-ran the race harness: **46/300 (15.3%) escapes** —
the race reappears at a rate consistent with the pre-fix measurements, confirming the fix (not
some unrelated timing change) is what closed it. **Mutation killed.**

This is also codified as `tests/test-persist-proposal.py`'s
`TestDirFdWritePath.test_mutation_forcing_path_based_writer_reproduces_the_race` (60 iterations,
asserts at least one escape when `DIR_FD_SUPPORTED` is forced False), so the mutation-kill
property is enforced on every run, not just this one-off report.

## 7. fd-leak check

Checked `/proc/self/fd` count before and after 200 successful writes (memory + skill each) and
200 failing writes (forced `PersistError` via a pre-existing directory colliding with `SKILL.md`,
after an earlier skill in the same batch had already opened/staged fds):

```
fd count before=4 after 200 successes=4 after 200 failures=4
```

No leak on either path. Codified as
`TestDirFdWritePath.test_no_fd_leak_across_many_successful_and_failed_writes` (50 iterations
each, skipped where `/proc/self/fd` doesn't exist, e.g. macOS).

## 8. Test changes

- `tests/test-adversarial-sweep.py`'s `TestTOCTOU.test_toctou_symlink_swap_race`: now branches on
  `WRITER_MOD.DIR_FD_SUPPORTED`. When true, asserts **zero** escapes (regression gate on the
  fix). When false (no-dir_fd platform), keeps the previous report-only behaviour with the
  0.5 sanity ceiling, now documented as applying only to that branch.
- `tests/test-persist-proposal.py`: added a `DIR_FD_SUPPORTED` capability probe (imported from
  the module under test, not reimplemented) alongside the existing `CAN_SYMLINK`/`CAN_HARDLINK`/
  `HAS_O_NOFOLLOW` probes, and a new `TestDirFdWritePath` class (dispatch check, fd-leak check,
  mutation-kill check) — 3 new tests, all skipped (not silently passed) where `DIR_FD_SUPPORTED`
  is false.
- `scripts/doctor.sh`: new "2b. dir_fd (TOCTOU) support" section.
- All prior tests (22 in `test-persist-proposal.py`, 32 in `test-adversarial-sweep.py` including
  the other 94 non-TOCTOU adversarial attacks) still pass unmodified in behaviour — confirmed
  under both the system `python3` and the CI-enforced `~/.pyenv/versions/3.9.24/bin/python3.9`.
- `bash tests/run-all.sh`: still discovers and passes all **31** suites (23 shell, 8 python) —
  count unchanged.

## 9. What's unverified / out of scope

- **macOS**: not tested in this pass (no macOS host available here). The fix is written against
  POSIX primitives (`dir_fd`, `O_NOFOLLOW`, `O_DIRECTORY`) that macOS's `os` module also exposes
  and that `os.supports_dir_fd`/the functional probe should detect equivalently, but this claim
  is reasoned, not measured, for macOS specifically.
- **Windows**: not tested (no Windows host available here; also structurally out of reach for
  the fixed path, since `DIR_FD_SUPPORTED` is expected to probe `False` there). The residual on
  Windows is unchanged from before this pass and is now explicitly disclosed in three places
  (module docstring, `_write_all_path` docstring, `doctor.sh`) rather than left to a single
  docstring sentence.
- **Iteration ceiling**: 300 iterations is 5-7.5x the task's/suite's baselines but is not an
  exhaustive proof of zero probability — a race with a sufficiently narrow additional window
  could in principle still exist below this measurement's sensitivity. The design argument (every
  operation after the root-level open is anchored to an fd, never a re-resolved path) is the
  actual basis for confidence, not the iteration count alone.
