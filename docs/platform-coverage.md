# Platform coverage — what "green" does and does not mean

CI runs `{ubuntu, macos, windows}-latest × Python {3.9, 3.13}` — six cells, full suite in
each. **No run id is pinned as "the current state"**; every previous version of this
document pinned one and went stale within hours. Get the current state with:

```bash
gh run list --branch main
gh run view <id>
```

The measurements below *are* pinned to a run id, deliberately and with a date, because a
measurement without its subject is not a measurement. Re-derive them rather than trusting
them (see "How to re-derive", below) — they drift whenever a suite gains or loses a probe.

## Green is not equal coverage

Every cell passing does not mean every cell ran the same assertions. On Windows a set of
tests skip, each **gated on a probe that verifies the limitation rather than inferring it
from the platform name**, and each printing its own reason. There is no single cause, and
the old shorthand "symlinks need elevation" was half wrong: the shell half of the suite
cannot create symlinks while the Python half can.

### Measured: run `30426182617`, 2026-07-29, windows-latest 3.13 vs ubuntu-latest 3.13

| | windows 3.13 | ubuntu 3.13 |
|---|---|---|
| shell `SKIP:` lines | **5** across 4 suites | 1 (the inverse: a Windows-only bash-flavour check) |
| Python skips | **21** across 5 suites | 13 across 2 suites |
| of which Windows-only | **11** | — |

The 11 Windows-only Python skips: `test-persist-proposal.py` 5, `test-adversarial-sweep.py`
3, `test-store-lock-writers.py` 3.

`test-telemetry.py`'s 4 skips are **on every cell on every platform** — no CI runner has a
Copilot or Claude store, so live telemetry extraction is exercised only on a developer
machine that has both harnesses installed. `test-win-dir-pin.py` is the inverse suite: 6
skip on Windows, 9 on Linux.

### The five shell skips, each with its probed cause

| Suite | Skips | Probed reason (verbatim from the run) |
|---|---|---|
| `test-path-compare-lib.sh` | 2 | `ln -s` could not create a symlink — *verified* with `[[ -L … ]]` being false after the attempt, not assumed |
| `test-copilot-hook-input.sh` | 1 | `no pty available to manufacture a real terminal fd on this platform` |
| `test-doctor.sh` | 1 | `chmod 500 did not make '<dir>' non-writable on this platform/filesystem` — verified by actually creating a file in it |
| `test-turn-counter.sh` | 1 | `could not build a usable jq-free PATH on this machine` |

That last row is **new since the previously documented figure of "4 shell skips across 3
suites"**, and it matters more than a count: it is the jq-failure-reporting path added in
`255a29f` (turn-counter reports a broken `jq` instead of silently resetting the counter).
That path is therefore unexercised on Windows.

### The eleven Windows-only Python skips

- `test-persist-proposal.py` (5) — `O_NOFOLLOW: UNAVAILABLE (POSIX-only primitive)` and
  `dir_fd (functional): UNAVAILABLE`. Note the same suite prints `symlink creation:
  AVAILABLE` and `hardlink creation: AVAILABLE`: Python **can** build the attack fixtures
  on Windows. What is missing is the defence, not the attack.
- `test-adversarial-sweep.py` (3) — `chmod read-only probed and not enforced` (×2), plus
  "POSIX permission bits are not meaningful on Windows/NTFS ACLs".
- `test-store-lock-writers.py` (3) — **`bash` is not runnable from Python on that runner**
  (probed). The bash-driven concurrent-writer scenarios therefore go unexercised on
  Windows. The lock backend itself *does* run there: the suite prints
  `store_lock backend=msvcrt`.

### What Windows covers that POSIX cannot

`test-win-dir-pin.py` prints `win32 directory pinning: AVAILABLE (verified: a pinned
directory could not be renamed, and our own staged replace inside it still succeeded)`.
The coverage asymmetry runs both ways.

### macOS

Green, with no macOS-specific skips beyond the universal `test-telemetry.py` 4 and the
inverse `test-win-dir-pin.py` 9.

## Lock backends are confirmed to execute, not merely to exist

`tests/test-persist-concurrency.py` prints `[capability probe] store_lock backend=…` on
every run. The matrix logs show `flock` on the ubuntu and macos cells and `msvcrt` on the
windows cells. Grep any run's log for `store_lock backend=` to see it.

## What CI cannot reach at all

- **No real harness hook has ever fired on Windows.** `install.ps1` is parse-checked and
  behaviourally tested on ubuntu runners (which ship `pwsh`), but CI never runs it on
  Windows, has no Copilot or VS Code session store, and never fires a hook from a real
  harness. [`windows-verification-runbook.md`](windows-verification-runbook.md) is the
  step-by-step protocol for closing that on a real machine.
- **The WSL-vs-Git-Bash PATH ambiguity is reasoned about but not CI-tested.** The wrappers
  refuse to delegate to a `bash` that cannot see this repository (a `test -f` probe on the
  exact script path). The *logic* is tested; the *environment* — a Windows box where WSL's
  `bash.exe` is first on PATH — cannot be reproduced without a Windows PowerShell CI job,
  which does not exist.
- **No real VS Code hook has invoked our scripts on any platform.** See the VS Code entry
  under "Known residuals" in the README.

## How to re-derive

Do not count by eye.

```bash
gh run list --branch main --limit 5
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.databaseId)\t\(.name)\t\(.conclusion)"'
gh run view <run-id> --job <windows-job-id> --log > /tmp/win.log
gh run view <run-id> --job <ubuntu-job-id>  --log > /tmp/ubu.log

# shell skips, attributed to their suite
awk '/=== tests\// {suite=$0} /SKIP:/ {print suite" ||| "$0}' /tmp/win.log

# python skips per suite
awk '/=== tests\// {suite=$0} /OK \(skipped=/ {print suite" -> "$0}' /tmp/win.log
```

Diff the Windows list against the Linux list: anything present on both is a universal
skip, not a Windows gap.
