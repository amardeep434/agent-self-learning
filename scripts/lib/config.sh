#!/usr/bin/env bash
# scripts/lib/config.sh
# Layered config: hardcoded defaults < config file < pre-set environment.
# Pre-set environment wins by snapshotting env values before sourcing the file.

_sl_env_snapshot=""
# Deferred minor 3: SL_STATE_DIR, SL_SKILLS_DIR, SL_MEMORY_DIR, SL_LOG_DIR,
# and SL_SEARCH_DB were missing from this list, so "env beats file" silently
# did NOT hold for any of them -- a config file could override a caller's
# pre-set environment variable for those five, the opposite of the
# documented contract at the top of this file.
for _v in SL_HOME SL_STATE_DIR SL_SKILLS_DIR SL_MEMORY_DIR SL_LOG_DIR SL_SEARCH_DB \
          SL_COACH_RULES_ENABLED SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH \
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
_sl_pp_sessions_db="" _sl_pp_config_file="" _sl_pp_scripts=""
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
            scripts)     _sl_pp_scripts="$_v" ;;
        esac
    done < <(python3 "$_sl_paths_py" all 2>/dev/null)
fi

# Degraded fallback only if python3/paths.py could not run at all (e.g. no
# python3 on PATH). paths.py remains the single authoritative resolver
# (global constraint); this is a bash-side MIRROR of its override chain
# (AGENT_LEARNING_HOME > XDG_DATA_HOME/agent-learning > $HOME default),
# not a reimplementation of its full resolution logic (no LOCALAPPDATA
# branch -- python3 is a hard dependency of this project's Windows CI, so
# this path only matters for Linux/macOS/Git-Bash boxes missing python3).
#
# I6 / deferred minor 3: commit 384a319 added a hardcoded
# ${HOME}/.local/share/agent-learning literal here to fix "never silently
# degrade to an empty path" -- but that literal ignores AGENT_LEARNING_HOME
# and XDG_DATA_HOME entirely, so on a python3-less box with
# AGENT_LEARNING_HOME set (e.g. for testing), files silently landed in a
# phantom, unconfigured store instead of the one the caller asked for. That
# is the same silent-wrong-location class as every other finding in this
# round, just introduced while fixing a different one.
_sl_compute_fallback_home() {
    if [[ -n "${AGENT_LEARNING_HOME:-}" ]]; then
        printf '%s' "$AGENT_LEARNING_HOME"
    elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
        printf '%s/agent-learning' "$XDG_DATA_HOME"
    else
        printf '%s/.local/share/agent-learning' "$HOME"
    fi
}
_sl_fallback_home="$(_sl_compute_fallback_home)"

SL_CONFIG_FILE="${SL_CONFIG_FILE:-${_sl_pp_config_file:-${_sl_fallback_home}/self-learning.conf}}"
if [[ -f "$SL_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SL_CONFIG_FILE"
fi

# Re-apply environment snapshot (env beats file)
eval "$_sl_env_snapshot"

# Defaults for anything still unset. Each falls back through the same
# AGENT_LEARNING_HOME/XDG_DATA_HOME/$HOME chain _sl_fallback_home computed
# above, so config.sh stays fully functional -- and honors the same
# overrides -- even with no python3 on PATH. Never silently degrading to an
# empty/root-relative path, and never reintroducing ~/.claude.
SL_HOME="${SL_HOME:-${_sl_pp_home:-${_sl_fallback_home}}}"
SL_STATE_DIR="${SL_STATE_DIR:-${_sl_pp_state:-${_sl_fallback_home}/state}}"
SL_SKILLS_DIR="${SL_SKILLS_DIR:-${_sl_pp_skills:-${_sl_fallback_home}/learned-skills}}"
SL_MEMORY_DIR="${SL_MEMORY_DIR:-${_sl_pp_memory:-${_sl_fallback_home}/memory}}"
SL_LOG_DIR="${SL_LOG_DIR:-${_sl_pp_logs:-${_sl_fallback_home}/logs}}"
SL_SEARCH_DB="${SL_SEARCH_DB:-${_sl_pp_sessions_db:-${_sl_fallback_home}/sessions/search.db}}"
SL_COACH_RULES_ENABLED="${SL_COACH_RULES_ENABLED:-false}"
SL_COACH_EXPORT_ENABLED="${SL_COACH_EXPORT_ENABLED:-false}"
SL_COACH_EXPORT_PATH="${SL_COACH_EXPORT_PATH:-${HOME}/.aiec/summary-latest.json}"
# I5 (Task 7b regression): this used to default to
# ${SL_HOME}/scripts/self-learning/coach-rules, but install.sh's Step 3b
# installs coach rules to ${DEST_DIR}/coach-rules where DEST_DIR is the
# "scripts" key from paths.py (${SL_HOME}/scripts, not
# .../scripts/self-learning). The two agreed until Task 7b moved DEST_DIR
# and this default was never updated -- so with SL_COACH_RULES_ENABLED=true
# on a real install, Route A silently evaluated against a directory that
# never existed and yielded {"signals": []} forever. Derive it from the
# SAME resolved "scripts" key install.sh itself uses, so the two can never
# independently drift apart again.
SL_COACH_RULES_DIR="${SL_COACH_RULES_DIR:-${_sl_pp_scripts:-${_sl_fallback_home}/scripts}/coach-rules}"
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

# I7: the contract for this function is full ISO-8601: a 'Z' suffix, an
# explicit "+HH:MM"/"-HH:MM" offset, and optional fractional seconds, all
# accepted on every platform. The GNU `date -d` branch below is lenient
# (accepts all of the above) and runs first on Linux, so Linux CI passed
# while quietly encoding GNU-specific leniency as the contract. macOS has no
# GNU date; its BSD `date -j -f` branch, and the python3 fallback below it,
# both used to hardcode the literal format "%Y-%m-%dT%H:%M:%SZ" -- so ANY
# offset or fractional-seconds timestamp fell through both and returned the
# "0" sentinel (1970, "infinitely stale") on macOS. That is silent and
# directional: the curator would archive skills it should keep, only on
# macOS, only for timestamps some code path had bothered to write with an
# explicit offset instead of always normalizing to Z.
#
# The python3 fallback now does a real ISO-8601 parse via
# datetime.fromisoformat, which is stdlib-only (no new dependency) and
# correctly preserves the sign of a negative offset (deferred minor 7: a
# prior strptime-based approach could not represent an offset at all, and a
# naive hand-rolled parser is exactly the kind of code that silently flips
# "-05:00" to "+05:00"; fromisoformat parses the sign itself, so there is no
# such step to get wrong). Python 3.9 (this project's oldest supported CI
# target) does not accept a trailing "Z" in fromisoformat, so it is swapped
# for the equivalent "+00:00" first.
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
ts = sys.argv[1]
if ts.endswith("Z"):
    ts = ts[:-1] + "+00:00"
try:
    dt = datetime.datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print(0)
' "$ts" 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    echo 0
}
