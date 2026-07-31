# Windows Python-first port — plan

**Status: NOT STARTED. Blocked on real Windows hardware.** Nothing below may be
implemented until Step 0 has been executed and its measurements written into this file.
Derived from the 2026-07-31 Windows dependency audit (sections F5-F8 of that audit).

## Why this plan exists

On Windows, every hook command in all three harness configs begins with `bash`, and
`install.ps1` / `uninstall.ps1` are ~28-line delegators that locate Git Bash and hand off
to `install.sh`. If Git Bash is unavailable — a corporate laptop that prohibits it — this
project has **zero** functionality on Windows: the installer refuses, and even a
hand-installed store never fires a hook.

The "bash core + PowerShell wrappers" decision assumed Git Bash was an inconvenience rather
than a blocker. It also predates the observation that the heavy logic — transcript parsing,
persistence, locking, indexing, path resolution, proposal schema — is **already**
cross-platform stdlib Python with Python test suites. The bash layer is glue, the
installer, and diagnostics.

## Verdict: Python-first with thin shims. PowerShell-first is REJECTED.

Rewriting the logic in PowerShell would create a **third implementation with no test
coverage** (every test in this repo is bash or Python) and would duplicate what Python
already does. The target is Python entry points, with a PowerShell shim only where a
harness insists on one:

- Windows hook configs invoke `python "<scripts>/turn_counter.py"` rather than
  `bash '<scripts>/turn-counter.sh'`. `ConvertFrom-Json` is never needed — the `json`
  stdlib module does it.
- `install.ps1` becomes either a real installer or (lazier) a ~50-line bootstrap that
  delegates to `python install.py`, shared with the POSIX path.
- Result: Windows dependencies shrink to python3 plus the harness binary. Git Bash gone.

## Groundwork already completed (2026-07-31)

The **jq elimination** half of the audit's recommendation is DONE on the audit-remediation
branch: `scripts/lib/jsonio.py` replaced every runtime jq call site except one. jq now has
a single runtime user, `scripts/turn-counter.sh`, where replacing it measured **97-129ms
against a <100ms hook budget** (baseline 67-71ms, sandboxed, native python3) and was
reverted under the plan's own budget guard. That measurement is itself an input to this
port: two extra python3 spawns cost ~55ms, so a Python-native turn counter must do its work
**inside one interpreter process**, not by shelling out from bash to Python twice.

## Dependency matrix (verbatim from the audit, F7)

| Dependency | Install time | Runtime (hooks/review) | Windows today | Declared in README? |
|---|---|---|---|---|
| bash 4+ | HARD (install.sh is the installer; .ps1 = 28-line delegator) | HARD (every hook command in all 3 harness configs is `bash '...'`; Copilot's "powershell" variant is `bash -lc`) | Git Bash or WSL | yes |
| jq | HARD (install.sh:92 preflight refuses) | HARD (hook-input parsing, turn counter, review gates, curator; loud-fail guards) | winget jq | yes |
| python3 3.9+ stdlib | HARD | HARD (paths.py resolved on EVERY hook via config.sh; transcript/persist/index all python) | winget Python | yes |
| sqlite3 module (not CLI) | — | HARD for indexing/telemetry | bundled w/ Python | yes (CLI marked optional — correct) |
| sqlite3 CLI | no | optional (health check degrades) | Git-for-Windows bundle | yes, marked optional |
| claude / copilot binary | at least one | review pipeline model calls | native Windows builds exist | yes |
| flock | no | POSIX lock path only; Windows uses msvcrt.locking (store_lock.py) | n/a | via README locking note |
| nohup, coreutils (date/stat/mktemp/sed) | yes (inside bash scripts) | yes | supplied by Git Bash | implied by bash |
| curl, gh | no | no — sync-coach-rules.sh only (maintainer vendor refresh) | n/a | correctly undeclared |
| git | repo acquisition only | no | n/a | n/a |
| PowerShell 7+ | wrapper + Copilot hooks host | Copilot CLI hook host on Windows | built-in / winget | yes (Copilot row) |

The jq row is now historical: see "Groundwork" above.

## **Step 0 (MANDATORY, blocking): fire ONE real hook on real Windows and measure**

**No port code may be written before this step is complete.** Hard rule 3 of this project
is *probe, never infer from a platform name*, and Windows hook execution is entirely
unmeasured territory: **no real harness hook has ever fired on Windows**, under the current
design or any other. Everything below Step 0 is a projection until it is not.

Step 0 produces, on a real Windows machine with a real harness installed:

1. One real hook fire, with the **verbatim payload** the harness delivered on stdin, for
   each of Claude Code and Copilot CLI. Payload shapes are to be probed, never inferred
   from the POSIX shapes.
2. A **timing measurement** of a Python-native hook entry point, the same way CLAUDE.md's
   figures were taken (`date +%s%N`, 5+ real runs), against the same <100ms budget. Windows
   process startup is slower than Linux; if a single `python.exe` spawn already exceeds the
   budget, the budget is what changes first, deliberately and in writing, exactly as it was
   amended from <50ms.
3. A check of whether `python` or `python3` is the resolvable name (the Microsoft Store
   app-execution alias makes this non-obvious) and whether the harness's hook host runs
   with a login-shell-like environment at all.

Write all three results into this file before proceeding. If they contradict the plan,
the plan changes.

## Minimal viable subset, in order of value

Effort figures are the audit's, and they exclude Step 0.

1. **`turn_counter.py` + `session_start_context.py` + hook JSON variants without `bash`** —
   hooks fire natively. ~2-3 days including tests; the logic is small and the
   error-discipline comments are the bulk of the existing scripts. Note the budget finding
   above: do the JSON read and write in the same process as the path resolution.
2. **Review launch in Python** — port `lib/review-common.sh`'s gating and detached launch
   (`transcript.py` and `persist-proposal.py` are already Python). ~3-5 days. The detach
   semantics are the subtle part: `nohup bash -c … &` becomes `subprocess.Popen` with
   `start_new_session` on POSIX and `DETACHED_PROCESS` on Windows, and this needs real
   measurement rather than reasoning.
3. **`install.py` / `uninstall.py`** — file copies, template rendering (`render-template.py`
   is already Python), hook-registration JSON edits (`normalize-hook-path.py` is already
   Python). ~3-4 days.
4. **`doctor.sh` / `self-learning-health.sh` / `curator-run.sh` ports** — deferrable.
   Diagnostics and maintenance; not needed for a working install.

Total realistic effort: **~2-3 weeks including Windows test coverage**, which is the
genuinely new cost — the current suites assume bash, and CI's Windows cells run them under
Git Bash.

## Caveats that survive the port

- **TOCTOU hardening stays POSIX-only.** `O_NOFOLLOW` and `dir_fd` do not exist on Windows;
  `persist-proposal.py` falls back regardless of which language calls it. A native port
  does not fix that and must not be sold as fixing it.
- **Windows-only Python skips are real coverage gaps**, not noise. See
  [`docs/platform-coverage.md`](../../platform-coverage.md) for the current re-derived
  counts and each skip's probed cause.
- **`claude` / `copilot` native-Windows hook payload shapes must be probed**, per Step 0.

## Source

`/home/amardeep/.claude/jobs/79e9b34f/tmp/audit/windows-deps.md`, sections F5-F8
(2026-07-31 dependency audit). This plan is the committed record of that audit's
recommendation; the audit file itself is outside the repository.
