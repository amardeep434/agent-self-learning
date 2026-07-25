#!/usr/bin/env bash
# scripts/doctor.sh — resolve and report framework state.
#
# The defect this framework shipped with was invisible: on Copilot CLI the
# background reviewer was told to write memory files itself; Copilot's path
# allow-list refused; the loop still exited 0, a log file still existed, and
# nothing was persisted. The review pipeline now runs fully detached
# (nohup ... &), which means its failures can never reach a hook's exit
# code at all -- ${SL_LOG_DIR}/persist-failures.log is the only mechanism
# that replaces that exit code, and surfacing it here is this script's
# single most important job. Every other section exists to answer "why did
# a path resolve here" and "is this install actually wired up" in seconds
# instead of months.
#
# No code in this file may reference ~/.claude, the `claude` binary, or
# CLAUDE.md as anything other than the legacy store it detects (never
# moves) and the Claude-Code-specific hook file it optionally inspects when
# `claude` is present. Nothing here is required for Copilot CLI or VS Code.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"

# --strict: opt-in, additionally fails (nonzero exit) on a stale hook config
# -- a hook registered in settings.json/self-learning.json that points at a
# scripts dir which is no longer the resolved one. Default (no flag)
# behaviour is UNCHANGED: a stale hook is still printed loudly (see
# _sl_report_hooks below) but never flips STATUS on its own, matching every
# doctor.sh run before this item. Without --strict, a CI job or wrapper
# script checking doctor's exit code can pass with genuinely broken hook
# wiring -- silent success on a broken state is exactly the pattern this
# project exists to eliminate, hence this flag.
#
# Deliberate exception, carried over unchanged: a detected LEGACY ~/.claude
# store (section 4 below) is never fatal, even under --strict. Every
# upgraded machine would go permanently red otherwise, and operators would
# learn to ignore the exit code entirely -- worse than not having --strict.
STRICT=0
for _arg in "$@"; do
    if [[ "$_arg" == "--strict" ]]; then
        STRICT=1
    fi
done

STATUS=0
STALE_HOOKS_FOUND=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Windows detection for display purposes only (which override in paths.py's
# chain won). The actual resolution is still done exclusively by paths.py;
# this mirrors its platform check, it never substitutes for it.
_sl_is_windows() {
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) return 0 ;;
    esac
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

# Which override in scripts/lib/paths.py's resolve_home() chain won. Display
# only -- printing just the final path hides the actual debugging question
# of *why* it resolved there.
_sl_resolve_source() {
    if [[ -n "${AGENT_LEARNING_HOME:-}" ]]; then
        echo "AGENT_LEARNING_HOME"
    elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
        echo "XDG_DATA_HOME"
    elif _sl_is_windows && [[ -n "${LOCALAPPDATA:-}" ]]; then
        echo "LOCALAPPDATA"
    else
        echo "default (\${HOME}/.local/share/agent-learning)"
    fi
}

# Actually test writability: create and remove a real temp file. Permission
# bits lie under many conditions (ACLs, read-only filesystems, containers
# running as an unexpected uid, Windows) -- this is the only honest test.
_sl_test_writable() {
    local dir="$1" tf
    mkdir -p "$dir" 2>/dev/null || return 1
    tf=$(mktemp "${dir%/}/.doctor-write-test.XXXXXX" 2>/dev/null) || return 1
    rm -f "$tf" 2>/dev/null
    return 0
}

# Report every expected <script>: hook in a config file, using the SAME
# sl_check_hook_fresh() helper (scripts/lib/config.sh) that
# self-learning-health.sh uses, so the two tools cannot disagree about the
# same file by construction. $1 = hook config file, $2.. = script basenames
# expected to be registered in it.
_sl_report_hooks() {
    local file="$1"; shift
    local script_name state
    for script_name in "$@"; do
        state="$(sl_check_hook_fresh "$file" "$script_name" "$SL_SCRIPTS_DIR")"
        case "$state" in
            absent)  echo "    ${script_name}: not installed" ;;
            missing) echo "    ${script_name}: MISSING -- not registered in ${file}" ;;
            stale)   echo "    ${script_name}: STALE -- registered but does not point at ${SL_SCRIPTS_DIR}/${script_name}"
                     STALE_HOOKS_FOUND=1 ;;
            fresh)   echo "    ${script_name}: registered, points at resolved scripts dir" ;;
        esac
    done
}

echo "agent-self-learning doctor"
echo "==========================="
echo

# ---------------------------------------------------------------------------
# 1. Resolved paths -- every key from paths.py, plus which override won.
# ---------------------------------------------------------------------------
SOURCE="$(_sl_resolve_source)"
echo "resolved paths (override source: ${SOURCE}):"
for pair in "home:${SL_HOME}" "memory:${SL_MEMORY_DIR}" "skills:${SL_SKILLS_DIR}" \
            "state:${SL_STATE_DIR}" "logs:${SL_LOG_DIR}" "sessions_db:${SL_SEARCH_DB}" \
            "config_file:${SL_CONFIG_FILE}"; do
    key="${pair%%:*}"; value="${pair#*:}"
    printf '  %-12s %s\n' "$key" "$value"
done

# "scripts" is not exported by config.sh (verified by reading it), so it is
# obtained the same way config.sh obtains everything else: shelling out to
# the single resolver, never recomputed here.
SL_SCRIPTS_DIR=""
_SL_PYTHON3_AVAILABLE=0
if command -v python3 >/dev/null 2>&1; then
    _SL_PYTHON3_AVAILABLE=1
    SL_SCRIPTS_DIR="$(python3 "${SCRIPT_DIR}/lib/paths.py" get scripts 2>/dev/null || true)"
fi
printf '  %-12s %s\n' "scripts" "${SL_SCRIPTS_DIR:-<unresolved: python3/paths.py unavailable>}"
echo

# ---------------------------------------------------------------------------
# 2. Writability -- actually tested, not inferred.
# ---------------------------------------------------------------------------
echo "writability (create+remove a real temp file, not permission-bit inference):"
for dir in "${SL_HOME}" "${SL_MEMORY_DIR}" "${SL_SKILLS_DIR}" "${SL_STATE_DIR}" "${SL_LOG_DIR}"; do
    if _sl_test_writable "$dir"; then
        printf '  %-60s writable\n' "$dir"
    else
        printf '  %-60s NOT WRITABLE\n' "$dir"
        STATUS=1
    fi
done
echo

# ---------------------------------------------------------------------------
# 2b. dir_fd (TOCTOU) support -- fix-p3-toctou.
#
# scripts/persist-proposal.py closes a symlink-swap race in its write path
# using dir_fd-anchored syscalls (O_NOFOLLOW open/mkdir/stat/replace/unlink
# relative to an already-open directory fd) wherever the platform actually
# supports them -- checked with a real functional probe at persist-proposal
# import time (_probe_dir_fd_support), not a platform-name guess or a bare
# os.supports_dir_fd lookup (which is demonstrably unreliable for
# os.replace specifically on this project's own Linux dev/CI host -- see
# that function's docstring). Where the probe fails (known case: native
# Windows, which has no dir_fd concept at all), persist-proposal.py falls
# back to the older path-based writer, which has a measured, disclosed
# TOCTOU residual (tests/test-adversarial-sweep.py's TestTOCTOU;
# .superpowers/sdd/2026-07-25-harness-neutral-persistence/fix-p3-toctou-report.md).
# Surfacing which mode is active here is the whole point: an operator
# should never have to read source to find out whether that residual
# applies to their install.
# ---------------------------------------------------------------------------
if [[ "${_SL_PYTHON3_AVAILABLE}" == "1" ]]; then
    # fix-p6: SCRIPT_DIR used to be baked into this -c source string as a
    # bash-interpolated literal (twice: sys.path.insert and
    # spec_from_file_location), the same pattern that broke a fix-p6 test
    # on Windows (Git Bash only auto-translates POSIX-style paths passed as
    # their OWN argv token to a native executable, not paths embedded
    # inside a quoted -c string). Passed as sys.argv[1] instead, matching
    # the safe pattern already used a few lines down in this same file
    # (legacy-home probe) and in tests/lib/path-compare.sh.
    DIR_FD_PROBE="$(python3 -c '
import sys
script_dir = sys.argv[1]
sys.path.insert(0, script_dir)
import importlib.util
spec = importlib.util.spec_from_file_location("persist_proposal", script_dir + "/persist-proposal.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("yes" if m.DIR_FD_SUPPORTED else "no")
' "${SCRIPT_DIR}" 2>/dev/null || echo "unknown")"
    case "${DIR_FD_PROBE}" in
        yes) echo "dir_fd TOCTOU fix: ACTIVE (persist-proposal.py writes are dir_fd-anchored; race closed)" ;;
        no)  echo "dir_fd TOCTOU fix: NOT AVAILABLE on this platform -- persist-proposal.py is using the" ;
             echo "  older path-based writer, which has a known, measured symlink-swap TOCTOU residual." ;
             echo "  See .superpowers/sdd/2026-07-25-harness-neutral-persistence/fix-p3-toctou-report.md." ;;
        *)   echo "dir_fd TOCTOU fix: could not probe (persist-proposal.py failed to import)" ;;
    esac
else
    echo "dir_fd TOCTOU fix: cannot probe -- python3 unavailable"
fi
echo

# ---------------------------------------------------------------------------
# 2c. Write-serialisation lock backend -- fix-p7-append-race.
#
# persist-proposal.py serialises its whole read-modify-write transaction
# with scripts/lib/store_lock.py. Which backend that module selects decides
# what happens when a holder crashes: the kernel-held backends (flock,
# msvcrt) are dropped by the OS on process death, so nothing can wedge;
# the O_CREAT|O_EXCL fallback instead breaks a lock older than
# STALE_SECONDS. An operator staring at "reviews stopped persisting" needs
# to know which of those applies without reading source -- and, if the lock
# is genuinely held, where the file is.
# ---------------------------------------------------------------------------
if [[ "${_SL_PYTHON3_AVAILABLE}" == "1" ]]; then
    # Same argv-not-interpolated-into--c discipline as 2b above (Git Bash
    # only auto-translates POSIX paths passed as their own argv token).
    LOCK_PROBE="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import store_lock
print(store_lock.BACKEND, "yes" if store_lock.BACKEND_RELEASES_ON_CRASH else "no")
' "${SCRIPT_DIR}" 2>/dev/null || echo "unknown unknown")"
    LOCK_BACKEND="${LOCK_PROBE%% *}"
    LOCK_CRASH_SAFE="${LOCK_PROBE##* }"
    case "${LOCK_BACKEND}" in
        flock|msvcrt)
            echo "write lock: ACTIVE, backend '${LOCK_BACKEND}' (kernel-held; released automatically" ;
            echo "  if a writer crashes, so a dead process cannot wedge future reviews)" ;;
        exclusive)
            echo "write lock: ACTIVE, backend 'exclusive' (O_CREAT|O_EXCL fallback -- no kernel" ;
            echo "  primitive probed usable here). A crashed writer's lock is broken by age" ;
            echo "  instead; delete ${SL_STATE_DIR}/persist.lock if reviews stop persisting." ;;
        *)
            echo "write lock: could not probe (scripts/lib/store_lock.py failed to import)" ;;
    esac
    if [[ "${LOCK_BACKEND}" != "unknown" && "${LOCK_CRASH_SAFE}" == "no" ]]; then
        echo "  lock file: ${SL_STATE_DIR}/persist.lock"
    fi
else
    echo "write lock: cannot probe -- python3 unavailable"
fi
echo

# ---------------------------------------------------------------------------
# 3. Detected harnesses -- presence + hook-config freshness.
#
# Round A finding: with python3 absent, SL_SCRIPTS_DIR resolves to "" (see
# above), and sl_check_hook_fresh() (lib/config.sh) treats an empty
# scripts_dir as "never fresh" -- so calling _sl_report_hooks() unguarded
# reported EVERY hook, even a genuinely fresh one, as STALE. That is a wrong
# diagnosis pinned on the hook config when the real blocker is a missing
# dependency this script never named. Round A fixed this exact shape in
# self-learning-health.sh; doctor.sh was out of that round's scope. Fail
# loudly and specifically instead: one clear message naming python3 as the
# cause, and skip the per-hook freshness checks entirely rather than emit
# misleading verdicts for them.
# ---------------------------------------------------------------------------
echo "harnesses detected:"

if command -v claude >/dev/null 2>&1; then
    echo "  claude   present (Claude Code)"
    CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
    echo "    hooks (~/.claude/settings.json):"
    if [[ "$_SL_PYTHON3_AVAILABLE" -eq 0 ]]; then
        echo "    cannot verify hook freshness -- python3 not found on PATH"
        echo "    Fix: install python3 so scripts/lib/paths.py (this project's sole path resolver) can run"
        STATUS=1
    else
        _sl_report_hooks "$CLAUDE_SETTINGS" turn-counter.sh session-review.sh index-session.sh
    fi
else
    echo "  claude   absent (normal on a Copilot-only or VS-Code-only machine)"
fi

if command -v copilot >/dev/null 2>&1; then
    echo "  copilot  present (Copilot CLI)"
    COPILOT_HOOKS="${HOME}/.copilot/hooks/self-learning.json"
    echo "    hooks (~/.copilot/hooks/self-learning.json):"
    if [[ "$_SL_PYTHON3_AVAILABLE" -eq 0 ]]; then
        echo "    cannot verify hook freshness -- python3 not found on PATH"
        echo "    Fix: install python3 so scripts/lib/paths.py (this project's sole path resolver) can run"
        STATUS=1
    else
        _sl_report_hooks "$COPILOT_HOOKS" copilot-session-review.sh
    fi
else
    echo "  copilot  absent (normal on a Claude-Code-only or VS-Code-only machine)"
fi

if command -v code >/dev/null 2>&1 || [[ -d "${HOME}/.vscode" ]]; then
    echo "  vscode   present (VS Code) -- Copilot Chat adapter/hooks are not yet"
    echo "           shipped by this release (tracked separately); nothing to check"
else
    echo "  vscode   absent"
fi
echo

# ---------------------------------------------------------------------------
# 4. Legacy ~/.claude store -- DETECT ONLY. Never move or modify user data.
# ---------------------------------------------------------------------------
LEGACY_HOME=""
if command -v python3 >/dev/null 2>&1; then
    LEGACY_HOME="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import paths
h = paths.legacy_home()
print(h if h else "")
' "${SCRIPT_DIR}/lib" 2>/dev/null || true)"
fi

echo "legacy store:"
if [[ -n "$LEGACY_HOME" ]]; then
    echo "  *** legacy ~/.claude store found: ${LEGACY_HOME} ***"
    echo "  this release stores data at: ${SL_HOME}"
    echo "  nothing has been moved or modified. To migrate deliberately, e.g.:"
    echo "    cp -r ${LEGACY_HOME}/memory ${LEGACY_HOME}/learned-skills ${SL_HOME}/"
else
    echo "  none found"
fi
echo

# ---------------------------------------------------------------------------
# 5. Persistence failures -- the load-bearing section. The review pipeline
# runs fully detached, so its failures cannot reach a hook exit code; this
# log is the only replacement for that signal, and this is the only place
# a human sees it. "log absent" and "log present but empty" are reported
# distinctly on purpose: absent can mean the pipeline has never even run.
# ---------------------------------------------------------------------------
FAILURE_LOG="${SL_LOG_DIR}/persist-failures.log"
echo "persistence failures (${FAILURE_LOG}):"
if [[ ! -e "$FAILURE_LOG" ]]; then
    echo "  ABSENT -- this can mean the review pipeline has never run yet, OR that"
    echo "  it has run and never failed. Absence alone is not proof of health."
elif [[ ! -s "$FAILURE_LOG" ]]; then
    echo "  present, EMPTY -- pipeline has run and recorded zero failures."
else
    COUNT="$(grep -c '' "$FAILURE_LOG" 2>/dev/null || echo 0)"
    LAST_LINE="$(tail -n 1 "$FAILURE_LOG")"
    LAST_TS="${LAST_LINE%% *}"
    LAST_EPOCH="$(sl_iso_to_epoch "$LAST_TS")"
    NOW_EPOCH="$(date -u +%s)"
    if [[ "$LAST_EPOCH" -gt 0 ]]; then
        AGE_SEC=$(( NOW_EPOCH - LAST_EPOCH ))
        AGE_DESC="${LAST_TS} (${AGE_SEC}s ago)"
    else
        AGE_DESC="unknown -- most recent line has an unparsable timestamp"
    fi
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !!! ${COUNT} PERSISTENCE FAILURE(S) RECORDED -- most recent: ${AGE_DESC}"
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  most recent entries (bounded tail, last 5 of ${COUNT}):"
    tail -n 5 "$FAILURE_LOG" | sed 's/^/    /'
    STATUS=1
fi
echo

# ---------------------------------------------------------------------------
# 5b. persist.log outcomes -- I9. This project's original defect (a reviewer
# whose output got wrapped by the harness so extraction broke) produces
# exit 0, a persist.log line of exactly
# {"written": [], "skipped": ["no-proposal"], "bytes": 0}, and NOTHING in
# persist-failures.log -- byte-identical to "genuinely nothing worth
# learning this cycle". persist-failures.log alone cannot distinguish the
# two; only a PATTERN across runs can. A single no-proposal result is
# unremarkable. A RUN of them, most recently, is not: SL_MEMORY_REVIEW_
# INTERVAL and SL_SKILL_REVIEW_INTERVAL both default to 10 turns, so three
# consecutive empty results mean the last three 10+-turn stretches of work
# produced not one memory or skill entry -- for an actively used install,
# that is far more consistent with broken extraction than with genuinely
# nothing worth learning three cycles running. Threshold is 3, deliberately
# small: false positives here just mean "look at review-stderr.log", while
# false negatives mean this section is the same kind of blind spot
# persist-failures.log alone already was.
# ---------------------------------------------------------------------------
PERSIST_LOG="${SL_LOG_DIR}/persist.log"
PERSIST_LOG_TAIL_N=10
NO_PROPOSAL_STREAK_THRESHOLD=3
echo "persist.log outcomes (last ${PERSIST_LOG_TAIL_N} runs, ${PERSIST_LOG}):"
if [[ ! -e "$PERSIST_LOG" ]]; then
    echo "  ABSENT -- the review pipeline has never completed a persist-proposal.py run yet."
elif [[ ! -s "$PERSIST_LOG" ]]; then
    echo "  present, EMPTY."
else
    TAIL_LINES="$(tail -n "$PERSIST_LOG_TAIL_N" "$PERSIST_LOG")"
    TOTAL_LINES="$(printf '%s\n' "$TAIL_LINES" | grep -c '' || echo 0)"
    # Reverse (most-recent-first) with the classic POSIX sed idiom -- `tac`
    # is GNU-only and stock macOS ships neither it nor GNU sed by default.
    REVERSED="$(printf '%s\n' "$TAIL_LINES" | sed '1!G;h;$!d')"
    STREAK=0
    while IFS= read -r line; do
        case "$line" in
            *'"skipped": ["no-proposal"]'*) STREAK=$((STREAK + 1)) ;;
            *) break ;;
        esac
    done <<< "$REVERSED"
    echo "  ${TOTAL_LINES} run(s) examined; ${STREAK} consecutive no-proposal result(s) most recently."
    if [[ "$STREAK" -ge "$NO_PROPOSAL_STREAK_THRESHOLD" ]]; then
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !!! SUSPICIOUS: ${STREAK} consecutive no-proposal results. This is"
        echo "  !!! byte-identical to the reviewer's output being wrapped in a way"
        echo "  !!! persist-proposal.py cannot extract a proposal from -- the exact"
        echo "  !!! defect class this project exists to eliminate. Check"
        echo "  !!! \${SL_LOG_DIR}/reviews/*.log and review-stderr.log, and consider a"
        echo "  !!! manual review run to confirm the reviewer is actually emitting JSON."
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        STATUS=1
    fi
fi
echo

# ---------------------------------------------------------------------------
# 5c. Coach Route A rule coverage -- fix-p5-coach. scripts/coach-rules-eval.py
# evaluates a fixed, measured subset of the 45 vendored rules, each an
# ADAPTATION to this project's own session data (never VS Code Copilot
# Chat's richer per-turn telemetry the upstream rules actually target -- see
# that script's module docstring). Surfacing the count here, not just in the
# script's own stderr, is the point: "45 rules vendored" must never read as
# "45 rules evaluated" to someone who only runs doctor.sh. Only run when
# Route A is enabled -- this is a diagnostic for an opt-in feature, not a
# reason to shell out to python3 on installs that never turned it on.
# ---------------------------------------------------------------------------
if [[ "${SL_COACH_RULES_ENABLED:-false}" == "true" ]]; then
    echo "coach rules (Route A) coverage:"
    if [[ "$_SL_PYTHON3_AVAILABLE" -eq 0 ]]; then
        echo "  cannot check -- python3 not found on PATH"
    elif [[ ! -d "${SL_COACH_RULES_DIR:-}" ]]; then
        echo "  rules dir not found: ${SL_COACH_RULES_DIR:-<unset>}"
    else
        COVERAGE_LINE="$(python3 "${SCRIPT_DIR}/coach-rules-eval.py" \
            "${SL_COACH_RULES_DIR}" "${SL_SEARCH_DB}" 2>&1 >/dev/null \
            | grep 'vendored rules evaluated' || true)"
        if [[ -n "$COVERAGE_LINE" ]]; then
            echo "  ${COVERAGE_LINE#coach-rules-eval: }"
            echo "  these are adaptations to this project's own data, not upstream-equivalent"
            echo "  -- see README.md's Coach signals row and coach-rules-eval.py's module docstring"
        else
            echo "  could not determine coverage (coach-rules-eval.py produced no coverage line)"
        fi
    fi
    echo
fi

echo "review enabled: ${SL_REVIEW_ENABLED}"
echo

if [[ "$STRICT" -eq 1 && "$STALE_HOOKS_FOUND" -eq 1 ]]; then
    echo "--strict: at least one STALE hook found above -- failing (default-mode doctor would still exit 0 for this alone)"
    STATUS=1
fi
echo

if [[ "$STATUS" -eq 0 ]]; then
    echo "overall: HEALTHY"
else
    echo "overall: UNHEALTHY -- see NOT WRITABLE, persistence failures, and/or --strict hook-staleness above"
fi

exit "$STATUS"
