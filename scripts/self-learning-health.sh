#!/usr/bin/env bash
#
# Self-learning system health check / diagnostics.
# Verifies all components are correctly installed and functioning.
#
# Checks:
# 1. Required directories exist
# 2. All scripts are present and executable
# 3. Hooks are registered in settings.json
# 4. Turn counter state is valid
# 5. SQLite search database is accessible
# 6. Learned skills usage file is valid
# 7. Required dependencies available
#
# Usage:
#   bash self-learning-health.sh          # Run all checks
#   bash self-learning-health.sh --quiet  # Only show failures
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/config.sh"

QUIET="${1:-}"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# --- Helpers ---

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    if [[ "$QUIET" != "--quiet" ]]; then
        echo "  [PASS] $1"
    fi
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  [FAIL] $1"
    if [[ -n "${2:-}" ]]; then
        echo "         Fix: $2"
    fi
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo "  [WARN] $1"
}

section() {
    if [[ "$QUIET" != "--quiet" ]]; then
        echo ""
        echo "=== $1 ==="
    fi
}

# --- Check 1: Required directories ---

section "Directories"

REQUIRED_DIRS=(
    "$SL_STATE_DIR"
    "$SL_SKILLS_DIR"
    "$(dirname "$SL_SEARCH_DB")"
    "${SL_LOG_DIR}/reviews"
    "${SL_LOG_DIR}/curator"
    "$SCRIPT_DIR"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        pass "$dir exists"
    else
        fail "$dir missing" "Run install.sh or: mkdir -p $dir"
    fi
done

# --- Check 2: Scripts present and executable ---

section "Scripts"

REQUIRED_SCRIPTS=(
    "turn-counter.sh"
    "session-review.sh"
    "index-session.sh"
    "index-session.py"
    "scan-threats.py"
    "skill-lifecycle.py"
    "curator-run.sh"
    "self-learning-health.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
    script_path="${SCRIPT_DIR}/${script}"
    if [[ -f "$script_path" ]]; then
        if [[ -x "$script_path" ]] || [[ "$script" == *.py ]]; then
            pass "$script present"
        else
            fail "$script not executable" "chmod +x $script_path"
        fi
    else
        fail "$script missing" "Run install.sh"
    fi
done

# --- Check 3: Hooks registered in settings.json ---
# This check is Claude-Code-specific: settings.json is Claude Code's own
# config file, not part of the framework's (vendor-neutral) store. On a
# Copilot-only machine it is normal and expected to be absent -- that is a
# WARN, never a FAIL, so a Copilot-only user never sees a spurious failure
# here.

section "Hook Registration (Claude Code)"

# Freshness (not just registration) is checked via sl_check_hook_fresh(),
# shared with scripts/doctor.sh in lib/config.sh, so the two diagnostic
# tools can never disagree about the same hook config file by construction.
# A prior version of this check here substring-matched only the script name
# anywhere in the file and reported [PASS] even when the registered command
# pointed at a stale, no-longer-resolved scripts path -- exactly the Task 7c
# bug class, and worse for being the tool that actually ships in every
# install while doctor.sh (which caught it) did not yet.
SETTINGS_FILE="${HOME}/.claude/settings.json"
if command -v python3 >/dev/null 2>&1; then
    SL_SCRIPTS_DIR="$(python3 "${SCRIPT_DIR}/lib/paths.py" get scripts 2>/dev/null || true)"
else
    SL_SCRIPTS_DIR=""
fi

# Deferred minor 10: when python3 is unavailable, SL_SCRIPTS_DIR silently
# resolved to "" here, and sl_check_hook_fresh() (lib/config.sh) treats an
# empty scripts_dir as "never fresh" -- so every hook was reported as
# STALE regardless of whether it was actually fine. That is a wrong
# diagnosis pinned on the hook config, when the real problem is a missing
# dependency this check never named. Fail loudly and specifically instead:
# one clear FAIL that says python3 is the blocker, and skip the per-hook
# freshness checks entirely rather than emit misleading verdicts for them.
if ! command -v python3 >/dev/null 2>&1; then
    fail "cannot verify hook freshness -- python3 not found on PATH" \
        "Install python3 so scripts/lib/paths.py (this project's sole path resolver) can run"
elif [[ -f "$SETTINGS_FILE" ]]; then
    for pair in "turn-counter.sh:PostToolUse turn-counter" \
                "session-review.sh:Stop session-review" \
                "index-session.sh:Stop index-session"; do
        script_name="${pair%%:*}"
        label="${pair#*:}"
        state="$(sl_check_hook_fresh "$SETTINGS_FILE" "$script_name" "$SL_SCRIPTS_DIR")"
        case "$state" in
            fresh)
                pass "$label hook registered and points at the resolved scripts dir"
                ;;
            stale)
                fail "$label hook registered but STALE -- does not point at ${SL_SCRIPTS_DIR}/${script_name}" \
                    "Re-render the hook command in ~/.claude/settings.json (e.g. re-run install.sh) so it points at ${SL_SCRIPTS_DIR}/${script_name}"
                ;;
            missing)
                fail "$label hook not found in settings.json" \
                    "Add $label hook for ${script_name} to ~/.claude/settings.json"
                ;;
        esac
    done
else
    warn "settings.json not found (normal on a Copilot-only install -- Claude Code hooks live here, Copilot hooks are registered separately under ~/.copilot/hooks/)"
fi

# --- Check 4: Turn counter state ---

section "Turn Counter"

COUNTER_FILE="${SL_STATE_DIR}/turn_counter.json"
if [[ -f "$COUNTER_FILE" ]]; then
    if jq empty "$COUNTER_FILE" 2>/dev/null; then
        pass "turn_counter.json is valid JSON"
        TOTAL=$(jq -r '.total_turns_this_session // 0' "$COUNTER_FILE" 2>/dev/null)
        if [[ "$QUIET" != "--quiet" ]]; then
            echo "         Current total turns: $TOTAL"
        fi
    else
        fail "turn_counter.json is corrupt" "Delete and let it recreate: rm $COUNTER_FILE"
    fi
else
    warn "turn_counter.json not found (normal if no session has run yet)"
fi

# Check for stale lock
LOCK_DIR="${SL_STATE_DIR}/counter.lock"
if [[ -d "$LOCK_DIR" ]]; then
    LOCK_MTIME=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
    LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
    if [[ "$LOCK_AGE" -gt 30 ]]; then
        warn "Stale lock directory found (${LOCK_AGE}s old). Removing."
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    else
        pass "Lock directory exists but is fresh (active operation)"
    fi
fi

# --- Check 5: SQLite search database ---

section "Session Search Database"

DB_PATH="$SL_SEARCH_DB"
if [[ -f "$DB_PATH" ]]; then
    if command -v sqlite3 &>/dev/null; then
        SESSION_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sessions" 2>/dev/null || echo "ERROR")
        if [[ "$SESSION_COUNT" == "ERROR" ]]; then
            fail "search.db exists but query failed" "Database may be corrupt. Delete and re-index."
        else
            pass "search.db accessible ($SESSION_COUNT sessions indexed)"
        fi
    else
        warn "sqlite3 not found -- cannot verify database"
    fi
else
    warn "search.db not found (normal if no session has been indexed yet)"
fi

# --- Check 6: Learned skills usage file ---

section "Learned Skills"

USAGE_FILE="${SL_SKILLS_DIR}/.usage.json"
if [[ -f "$USAGE_FILE" ]]; then
    if jq empty "$USAGE_FILE" 2>/dev/null; then
        SKILL_COUNT=$(jq 'keys | length' "$USAGE_FILE" 2>/dev/null || echo 0)
        pass ".usage.json is valid JSON ($SKILL_COUNT skills tracked)"

        # Check for skills in invalid states
        INVALID=$(jq '[to_entries[] | select(.value.state != "active" and .value.state != "stale" and .value.state != "archived")] | length' "$USAGE_FILE" 2>/dev/null || echo 0)
        if [[ "$INVALID" -gt 0 ]]; then
            warn "$INVALID skill(s) in invalid state (expected: active, stale, or archived)"
        fi
    else
        fail ".usage.json is corrupt" "Back up and recreate: cp $USAGE_FILE ${USAGE_FILE}.bak && echo '{}' > $USAGE_FILE"
    fi
else
    warn ".usage.json not found (normal if no skills have been learned yet)"
fi

# --- Check 7: Dependencies ---

section "Dependencies"

for cmd in jq sqlite3 python3; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd available ($(command -v "$cmd"))"
    else
        fail "$cmd not found" "Install $cmd (required for self-learning system)"
    fi
done

# --- Summary ---

echo ""
echo "=============================="
echo "Health Check Summary"
echo "=============================="
echo "  Passed:   $PASS_COUNT"
echo "  Failed:   $FAIL_COUNT"
echo "  Warnings: $WARN_COUNT"
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "Status: UNHEALTHY ($FAIL_COUNT failure(s) found)"
    exit 1
else
    echo "Status: HEALTHY"
    exit 0
fi
