# Windows Interpreter-Resolution Fix Plan (2026-08-04)

> **For agentic workers:** Execute IN ORDER, no deviation, no added scope. Evidence base: `/home/amardeep/.claude/jobs/79e9b34f/tmp/audit/windows-reality-audit.md` — read the cited area before each task. Field context: the owner's real Windows laptop fails `install.sh` preflight with "python not found" while `python --version` works; CI never caught it because `.github/workflows/ci.yml:37-47` manufactures a `python3.exe` alias real Windows lacks.

**Goal:** The repo runs on a machine where Python 3 exists only as `python` or `py -3` (and where a fake Windows-Store `python3.exe` stub may shadow the name), with one resolution point, loud failures, honest CI, and complete CRLF discipline.

**Architecture:** Single resolver sourced everywhere (WP1) → mechanical migration with three hand-fix classes (WP2) → PS1 parity + fallback-store repair (WP3) → regression test THAT FAILS ON TODAY'S MAIN plus CI-shim deletion in the same commit series (WP4) → CRLF completion (WP5) → docs (WP6). Owner-side probe checklist ships in the PR body (WP7).

**Branch:** `fix/windows-python-resolution` off current `main`.

## Global Constraints (binding — repo CLAUDE.md)

- POSIX bash, stdlib-only Python 3.9+, fail loudly with named persist-failures.log reasons, probe never infer, sandbox all store-touching runs (`env -i HOME=<tmp> PATH="$PATH" AGENT_LEARNING_HOME=<tmp>/store SL_CONFIG_FILE=/nonexistent`), never hardcode suite counts, conventional commits, no attribution.
- **Hook budget <100ms** with native python3 on PATH — the resolver adds spawns to EVERY hook fire; measure turn-counter before/after (6 runs, `date +%s%N`, sandboxed) and record numbers in the commit body. Resolution must be at most one extra `command -v` + one `--version` per hook invocation on the happy path (python3 exists and is real); cache within the invocation via the exported var.
- The WP2 sed is BLIND — after each file, `git diff` that file and revert any hit inside: regex/grep patterns, prose in heredocs or echo'd docs, comments where `python3` names the dependency concept rather than an invocation, and tests that deliberately probe the bare name.

## Journal (resume protocol)

`/home/amardeep/.claude/jobs/79e9b34f/tmp/audit/execution-journal-3.md`. If it exists at start: read, resume at first unticked. Else create with task list (0, WP1-WP6, G1-G5) unticked. Tick with sha after EVERY commit, never batched.

---

### Task 0: Branch + plan/audit committed
- [ ] `git checkout main && git pull && git checkout -b fix/windows-python-resolution`
- [ ] Copy this plan → `docs/superpowers/plans/2026-08-04-windows-python-resolution.md`; copy the audit → `docs/superpowers/2026-08-04-windows-reality-audit.md`.
- [ ] Commit: `docs: add Windows reality audit and interpreter-resolution plan`

### Task WP1: resolver [audit Area 2]
**Files:** Create `scripts/lib/python-resolve.sh`; Test `tests/test-python-resolve.sh` (new).
- [ ] **Step 1 (RED):** New test: (a) PATH with only a real `python` (3.x) → resolver exports SL_PYTHON pointing at it; (b) PATH with a FAKE `python3` stub that exits nonzero printing nothing (simulate the Store stub) plus a real `python` → resolver skips the stub, picks python; (c) PATH with no Python at all → resolver returns nonzero and prints all three tried names; (d) real `python3` present → picked first, zero extra spawns beyond the two probes. Build fakes as scripts in a temp bin dir. Run → FAIL (file absent).
- [ ] **Step 2 (GREEN):**
```bash
#!/usr/bin/env bash
# Single point of Python-3 resolution. python.org/winget/Store installs on
# Windows create `python.exe` and the `py` launcher but never `python3`;
# Windows also ships a fake Store `python3.exe` App Execution Alias that
# prints nothing and fails. So: presence is NOT enough — a candidate counts
# only if `--version` succeeds and reports Python 3.
#
# Sourced by config.sh (every hook fire) and install.sh (preflight). Exports
# SL_PYTHON as an absolute path so `"${SL_PYTHON}"` stays one word everywhere.

sl_resolve_python() {
    if [[ -n "${SL_PYTHON:-}" ]]; then
        return 0    # already resolved this process tree; keep hook cost flat
    fi
    local candidate resolved version
    for candidate in python3 python; do
        resolved="$(command -v "$candidate" 2>/dev/null)" || continue
        version="$("$resolved" --version 2>&1)" || continue
        [[ "$version" == Python\ 3* ]] || continue
        SL_PYTHON="$resolved"
        export SL_PYTHON
        return 0
    done
    # Windows py launcher last: `py -3` is two words, so wrap it once.
    if command -v py >/dev/null 2>&1 && py -3 --version 2>&1 | grep -q '^Python 3'; then
        SL_PYTHON="$(py -3 -c 'import sys; print(sys.executable)')" \
            && [[ -n "$SL_PYTHON" ]] && export SL_PYTHON && return 0
    fi
    echo "agent-self-learning: no Python 3 found (tried: python3, python, py -3)." >&2
    echo "  On Windows: winget install Python.Python.3.12 -- and beware the fake" >&2
    echo "  Microsoft-Store 'python3' alias, which exists but is not Python." >&2
    return 1
}
```
- [ ] **Step 3:** Test → PASS. Commit: `feat: single-point Python 3 resolution that defeats the Store stub`

### Task WP2: migration [audit Areas 1+2]
**Files:** `scripts/lib/config.sh` (source resolver at top, fail loudly to persist-failures.log if resolution fails), `install.sh` preflight, then every `python3 ` invocation across scripts/*.sh, scripts/lib/*.sh, install.sh, uninstall.sh.
- [ ] **Step 1:** config.sh: source python-resolve.sh before the paths.py spawn (line ~55); on resolver failure write named reason `python3_unresolvable` via the existing failure-log helper and return/exit per config.sh's established degraded-path style. install.sh preflight (~:93): replace `for cmd in python3` with the resolver call; keep jq handling untouched.
- [ ] **Step 2:** Per file: `sed -i 's/\bpython3 /"${SL_PYTHON}" /g'`, then `git diff <file>` and hand-revert data hits (patterns, prose, deliberate bare-name tests). Hand-fix classes: (a) `review-common.sh:287` single-quoted `nohup bash -c` body → use `"${SL_PYTHON:-python3}"` inside (env var crosses the boundary because SL_PYTHON is exported); (b) every `command -v python3` guard → resolver-based check with the SAME loud-failure text style each guard already has; (c) any `python3 -c` inline in doctor.sh / health / sync-coach-rules.sh.
- [ ] **Step 3:** `bash -n` every touched file. Full sandboxed `bash tests/run-all.sh` → all pass.
- [ ] **Step 4 (BUDGET):** turn-counter timing, 6 runs sandboxed, before vs after; all <100ms with native python3 → record in commit body. Regression >100ms → cache harder (resolution already short-circuits on exported SL_PYTHON; verify the export actually reaches the hook process) — do not ship a busted budget.
- [ ] **Step 5:** Commit: `fix: every Python invocation goes through SL_PYTHON`

### Task WP3: PS1 parity + fallback-store repair [audit Areas 1+4]
**Files:** `install.ps1`, `scripts/lib/config.sh` fallback block (:63-84).
- [ ] **Step 1:** install.ps1: before delegating to bash, probe python3/python/`py -3` functionally (`--version` must report Python 3); on failure, stop with the winget line + Store-stub warning. Mirror find-bash.ps1's probe style.
- [ ] **Step 2:** config.sh `_sl_compute_fallback_home`: add the LOCALAPPDATA branch (Git Bash exports `LOCALAPPDATA`) so bash-fallback and paths.py resolve the SAME store on Windows; replace the `2>/dev/null` on the paths.py spawn with captured stderr and a named `paths_resolution_degraded` line to persist-failures.log when the fallback engages (rule 2 — the current silence is a violation).
- [ ] **Step 3 (test):** extend `tests/test-config.sh` (or the suite covering fallback resolution — find it): with `LOCALAPPDATA` set and paths.py unavailable, fallback must resolve `$LOCALAPPDATA/agent-learning`. RED first. Run → PASS. Commit: `fix: PS1 python preflight; fallback store matches paths.py on Windows, degrades loudly`

### Task WP4: regression guard + honest CI [audit Area 5]
**Files:** Create `tests/test-no-python3-name.sh`; Modify `.github/workflows/ci.yml` (delete the :37-47 "Ensure python3 resolves (Windows)" shim).
- [ ] **Step 1:** New test (this is the test that would have caught the owner's laptop): build a PATH with NO `python3` but a real `python` shim delegating to the system interpreter → assert (a) install.sh preflight passes, (b) config.sh resolves the store identically to paths.py, (c) one hook (turn-counter) processes a payload end to end. Variant (d): add a fake Store-stub `python3` in front → same three assertions still hold. MUST FAIL against pre-WP2 code — verify by `git stash`-running it against HEAD~ of the migration commit (journal the observed failure), then confirm PASS on the branch.
- [ ] **Step 2:** Delete the ci.yml shim step in the same commit as the test lands. `bash -n`-equivalent: yamllint if available, else careful diff.
- [ ] **Step 3:** Commit: `test: guard the python3-less Windows PATH; CI stops manufacturing python3`

### Task WP5: CRLF completion [audit Area 4]
**Files:** `scripts/lib/isotime.py`, `scripts/lib/list-transcripts.py`, `scripts/lib/session_db.py`, `scripts/lib/transcript.py`.
- [ ] **Step 1:** Add the round-E `sys.stdout.reconfigure(newline="\n")` block (copy paths.py's comment style, one line of why) at each module's CLI entry. Audit the inline `-c` consumers in doctor.sh/review-common.sh/sync-coach-rules.sh — where output feeds bash comparisons, either the producer got the fix above or add consumer-side `${var%$'\r'}` with a one-line comment.
- [ ] **Step 2:** Run the transcript/index/doctor suites → PASS. Commit: `fix: LF-only stdout for every python whose output bash consumes`

### Task WP6: docs [audit Area 6]
**Files:** `README.md` (dependency table :49-59, Windows quickstart), `docs/windows-verification-runbook.md` (its own first command is `python3` — lines 65/120/147/210), `CLAUDE.md` (hook-budget note if the measured numbers moved).
- [ ] **Step 1:** Dependency row: "Python 3.9+ — any of `python3`, `python`, or the `py -3` launcher; resolution is automatic and validates the interpreter actually runs (the fake Microsoft-Store `python3` alias is detected and skipped)". Runbook: replace bare `python3` with the resolver-aware invocation or `python`. CLAUDE.md budget paragraph: update measured figures if they changed.
- [ ] **Step 2:** Commit: `docs: Windows python reality — dependency wording, runbook, budget figures`

### FINAL GATE
- [ ] **G1:** live-store byte count before → journal. **G2:** full `bash tests/run-all.sh` → pass. **G3:** byte count after → compare. **G4:** `git log --oneline main..HEAD` conventional. 
- [ ] **G5:** Push, DRAFT PR to main titled `Windows: resolve Python by reality, not by name` — body: root cause (owner's laptop repro + CI shim admission), per-WP summary, budget numbers, and the WP7 owner probe checklist verbatim from the audit doc ("run these on the laptop after merging"). Journal PR URL + deltas.
