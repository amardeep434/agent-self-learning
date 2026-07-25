#!/usr/bin/env bash
# scripts/lib/config.sh
# Layered config: hardcoded defaults < config file < pre-set environment.
# Pre-set environment wins by snapshotting env values before sourcing the file.

_sl_env_snapshot=""
for _v in SL_HOME SL_COACH_RULES_ENABLED SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH \
          SL_COACH_RULES_DIR SL_MEMORY_REVIEW_INTERVAL SL_SKILL_REVIEW_INTERVAL \
          SL_REVIEW_MIN_TURNS SL_REVIEW_MAX_TURNS SL_COPILOT_REVIEW_MODEL \
          SL_SKILLOPT_ENABLED SL_SKILLOPT_REPO SL_SKILLOPT_RUN_CONFIRMED \
          SL_REVIEW_ENABLED; do
    if [[ -n "${!_v+x}" ]]; then
        _sl_env_snapshot+="${_v}=$(printf '%q' "${!_v}");"
    fi
done

# Paths come from scripts/lib/paths.py — the single resolver shared with Python.
# Never recompute them here; bash and python disagreeing across three operating
# systems is exactly the drift this indirection prevents. Resolved once, early,
# because SL_CONFIG_FILE (needed before we can even source the config file)
# must come from the same resolver as everything else — it may not default
# into ~/.claude any more than SL_HOME may.
_sl_paths_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.py"
_sl_pp_home="" _sl_pp_state="" _sl_pp_skills="" _sl_pp_memory="" _sl_pp_logs=""
_sl_pp_sessions_db="" _sl_pp_config_file=""
if [[ -f "$_sl_paths_py" ]]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            home)        _sl_pp_home="$_v" ;;
            state)       _sl_pp_state="$_v" ;;
            skills)      _sl_pp_skills="$_v" ;;
            memory)      _sl_pp_memory="$_v" ;;
            logs)        _sl_pp_logs="$_v" ;;
            sessions_db) _sl_pp_sessions_db="$_v" ;;
            config_file) _sl_pp_config_file="$_v" ;;
        esac
    done < <(python3 "$_sl_paths_py" all 2>/dev/null)
fi

# Degraded fallback only if python3/paths.py could not run at all (e.g. no
# python3 on PATH). Kept vendor-neutral so it never regresses the Copilot/VS
# Code constraint even in this edge case.
SL_CONFIG_FILE="${SL_CONFIG_FILE:-${_sl_pp_config_file:-${HOME}/.local/share/agent-learning/self-learning.conf}}"
if [[ -f "$SL_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SL_CONFIG_FILE"
fi

# Re-apply environment snapshot (env beats file)
eval "$_sl_env_snapshot"

# Defaults for anything still unset. Each falls back to the same
# vendor-neutral literal paths.py would produce on Linux/macOS with no
# overrides, so config.sh stays fully functional even with no python3 on
# PATH — never silently degrading to an empty/root-relative path, and never
# reintroducing ~/.claude.
SL_HOME="${SL_HOME:-${_sl_pp_home:-${HOME}/.local/share/agent-learning}}"
SL_STATE_DIR="${SL_STATE_DIR:-${_sl_pp_state:-${HOME}/.local/share/agent-learning/state}}"
SL_SKILLS_DIR="${SL_SKILLS_DIR:-${_sl_pp_skills:-${HOME}/.local/share/agent-learning/learned-skills}}"
SL_MEMORY_DIR="${SL_MEMORY_DIR:-${_sl_pp_memory:-${HOME}/.local/share/agent-learning/memory}}"
SL_LOG_DIR="${SL_LOG_DIR:-${_sl_pp_logs:-${HOME}/.local/share/agent-learning/logs}}"
SL_SEARCH_DB="${SL_SEARCH_DB:-${_sl_pp_sessions_db:-${HOME}/.local/share/agent-learning/sessions/search.db}}"
SL_COACH_RULES_ENABLED="${SL_COACH_RULES_ENABLED:-false}"
SL_COACH_EXPORT_ENABLED="${SL_COACH_EXPORT_ENABLED:-false}"
SL_COACH_EXPORT_PATH="${SL_COACH_EXPORT_PATH:-${HOME}/.aiec/summary-latest.json}"
SL_COACH_RULES_DIR="${SL_COACH_RULES_DIR:-${SL_HOME}/scripts/self-learning/coach-rules}"
SL_COACH_SIGNALS_FILE="${SL_COACH_SIGNALS_FILE:-${SL_STATE_DIR}/coach-signals.json}"
SL_MEMORY_REVIEW_INTERVAL="${SL_MEMORY_REVIEW_INTERVAL:-10}"
SL_SKILL_REVIEW_INTERVAL="${SL_SKILL_REVIEW_INTERVAL:-10}"
SL_REVIEW_MIN_TURNS="${SL_REVIEW_MIN_TURNS:-5}"
SL_REVIEW_MAX_TURNS="${SL_REVIEW_MAX_TURNS:-16}"
SL_COPILOT_REVIEW_MODEL="${SL_COPILOT_REVIEW_MODEL:-}"
SL_SKILLOPT_ENABLED="${SL_SKILLOPT_ENABLED:-false}"
SL_SKILLOPT_REPO="${SL_SKILLOPT_REPO:-}"
SL_SKILLOPT_RUN_CONFIRMED="${SL_SKILLOPT_RUN_CONFIRMED:-false}"

# SL_REVIEW_ENABLED supersedes CLAUDE_REVIEW_ENABLED. The legacy name is
# honored for one release so existing installs do not change behavior on
# upgrade; it is Claude-branded and read on the Copilot path, which is
# precisely the vendor coupling this release removes.
if [[ -z "${SL_REVIEW_ENABLED:-}" && -n "${CLAUDE_REVIEW_ENABLED:-}" ]]; then
    SL_REVIEW_ENABLED="$CLAUDE_REVIEW_ENABLED"
    echo "agent-self-learning: CLAUDE_REVIEW_ENABLED is deprecated; use SL_REVIEW_ENABLED" >&2
fi
SL_REVIEW_ENABLED="${SL_REVIEW_ENABLED:-true}"

export SL_HOME SL_STATE_DIR SL_SKILLS_DIR SL_MEMORY_DIR SL_LOG_DIR SL_SEARCH_DB \
       SL_COACH_RULES_ENABLED SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH \
       SL_COACH_RULES_DIR SL_COACH_SIGNALS_FILE \
       SL_MEMORY_REVIEW_INTERVAL SL_SKILL_REVIEW_INTERVAL \
       SL_REVIEW_MIN_TURNS SL_REVIEW_MAX_TURNS SL_COPILOT_REVIEW_MODEL \
       SL_SKILLOPT_ENABLED SL_SKILLOPT_REPO SL_SKILLOPT_RUN_CONFIRMED \
       SL_REVIEW_ENABLED

# ---------------------------------------------------------------------------
# sl_iso_to_epoch <iso8601-timestamp>
# Portable replacement for `date -d "$ts" +%s`, which is GNU-only and not
# available on macOS/BSD date. Timestamps in this project are always written
# with `date -u +%Y-%m-%dT%H:%M:%SZ` (see session-review.sh, curator-run.sh,
# turn-counter.sh), so all three strategies below parse that exact format.
# Tries GNU date, then BSD date, then falls back to python3 (stdlib only,
# already a hard dependency of this project). Prints "0" and returns success
# if the timestamp is empty or unparsable by every strategy, matching the
# previous `|| echo 0` fallback behavior at call sites.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# sl_check_hook_fresh <hook-config-file> <script-basename> <resolved-scripts-dir>
#
# Shared by scripts/doctor.sh and scripts/self-learning-health.sh so the two
# diagnostic tools can never disagree about the same hook config by
# construction. A prior version of this check (self-learning-health.sh)
# substring-matched only the script *name* anywhere in the file, so a hook
# config left pointing at a stale, no-longer-resolved scripts directory
# still read as registered and healthy -- precisely the Task 7c bug class,
# just invisible to the one tool that ships in a real install.
#
# Prints exactly one of:
#   absent  - the hook config file itself does not exist
#   missing - the file exists but never mentions <script-basename> at all
#   stale   - it mentions <script-basename>, but not under <resolved-scripts-dir>
#   fresh   - it mentions <script-basename> under <resolved-scripts-dir>
# ---------------------------------------------------------------------------
sl_check_hook_fresh() {
    local file="$1" script_name="$2" scripts_dir="$3"
    if [[ ! -f "$file" ]]; then
        echo "absent"
        return 0
    fi
    if ! grep -q -- "$script_name" "$file" 2>/dev/null; then
        echo "missing"
        return 0
    fi
    if [[ -n "$scripts_dir" ]] && grep -qF -- "${scripts_dir%/}/${script_name}" "$file" 2>/dev/null; then
        echo "fresh"
    else
        echo "stale"
    fi
}

sl_iso_to_epoch() {
    local ts="$1" epoch
    if [[ -z "$ts" ]]; then
        echo 0
        return 0
    fi
    epoch=$(date -u -d "$ts" +%s 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    epoch=$(python3 -c '
import datetime, sys
try:
    dt = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print(0)
' "$ts" 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    echo 0
}
