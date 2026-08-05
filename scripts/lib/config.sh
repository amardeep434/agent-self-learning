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
          SL_COPILOT_MAX_AI_CREDITS SL_VSCODE_REVIEWER \
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
_sl_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sl_paths_py="${_sl_lib_dir}/paths.py"
_sl_isotime_py="${_sl_lib_dir}/isotime.py"
_sl_pp_home="" _sl_pp_state="" _sl_pp_skills="" _sl_pp_memory="" _sl_pp_logs=""
_sl_pp_sessions_db="" _sl_pp_config_file="" _sl_pp_scripts=""

# The interpreter is resolved BEFORE the paths.py spawn below, because that
# spawn is the first Python use in every flow -- and "python3" is a name real
# Windows Python installs never provide. lib/python-resolve.sh is the single
# place that decides; nothing here may fall back to a bare name.
# shellcheck source=scripts/lib/python-resolve.sh
source "${_sl_lib_dir}/python-resolve.sh"
sl_resolve_python || true      # loud reporting happens below, once paths are known

# _sl_config_degraded <reason-slug> <human sentence>
#
# Rule 2 (fail loudly): config.sh is sourced by every hook, so a broken
# precondition here is invisible unless it reaches persist-failures.log --
# the one channel doctor.sh reads. It is also sourced on EVERY tool use, so
# an unthrottled append would bury doctor.sh's "N persistence failure(s)"
# count under thousands of identical lines. Same trade turn-counter.sh
# already makes, same marker-file shape, one line per interval per reason.
_SL_CONFIG_DEGRADED_INTERVAL="${_SL_CONFIG_DEGRADED_INTERVAL:-3600}"
_sl_config_degraded() {
    local slug="$1" sentence="$2" log_dir marker now last=0
    log_dir="${_sl_pp_logs:-${_sl_fallback_home}/logs}"
    marker="${log_dir}/.config-degraded.${slug}"
    now="$(date +%s 2>/dev/null)" || return 0
    mkdir -p "$log_dir" 2>/dev/null || return 0
    if [[ -f "$marker" ]]; then
        read -r last < "$marker" || last=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        (( now - last < _SL_CONFIG_DEGRADED_INTERVAL )) && return 0
    fi
    printf '%s\n' "$now" > "$marker" 2>/dev/null || true
    printf '%s config: %s -- %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$sentence" \
        >> "${log_dir}/persist-failures.log" 2>/dev/null || true
}

# Degraded fallback only if the interpreter or paths.py could not run at all.
# paths.py remains the single authoritative resolver (global constraint); this
# is a bash-side MIRROR of its override chain, in its exact order:
# AGENT_LEARNING_HOME > XDG_DATA_HOME/agent-learning > (Windows only)
# %LOCALAPPDATA%/agent-learning > $HOME/.local/share/agent-learning.
#
# The LOCALAPPDATA branch used to be missing, with a comment claiming python3
# was a hard dependency of Windows CI so the fallback could not matter there.
# That was exactly backwards on a REAL Windows machine, which is where
# resolution fails: paths.py resolves %LOCALAPPDATA%\agent-learning while this
# fallback resolved C:\Users\<u>\.local\share\agent-learning -- two stores,
# silently, the class this project exists to eliminate.
#
# I6 / deferred minor 3: commit 384a319 added a hardcoded
# ${HOME}/.local/share/agent-learning literal here to fix "never silently
# degrade to an empty path" -- but that literal ignores AGENT_LEARNING_HOME
# and XDG_DATA_HOME entirely, so on a python3-less box with
# AGENT_LEARNING_HOME set (e.g. for testing), files silently landed in a
# phantom, unconfigured store instead of the one the caller asked for. That
# is the same silent-wrong-location class as every other finding in this
# round, just introduced while fixing a different one.
#
# Computed BEFORE the paths.py spawn (it used to sit after it) because
# _sl_config_degraded needs a log directory to report INTO when that spawn
# is the thing that failed.
_sl_compute_fallback_home() {
    if [[ -n "${AGENT_LEARNING_HOME:-}" ]]; then
        printf '%s' "$AGENT_LEARNING_HOME"
    elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
        printf '%s/agent-learning' "$XDG_DATA_HOME"
    elif [[ -n "${LOCALAPPDATA:-}" && ( -n "${MSYSTEM:-}" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ]]; then
        # Windows is decided by two values that only exist there together, not
        # by a platform NAME: LOCALAPPDATA (which Git Bash inherits and
        # exports) plus an MSYS/Cygwin marker. LOCALAPPDATA alone would also
        # match a Wine/WSL environment carrying it through WSLENV, where
        # paths.py -- which branches on sys.platform -- would NOT take this
        # branch, and the two must agree or the store forks in two.
        printf '%s/agent-learning' "$LOCALAPPDATA"
    else
        printf '%s/.local/share/agent-learning' "$HOME"
    fi
}
_sl_fallback_home="$(_sl_compute_fallback_home)"

if [[ -z "${SL_PYTHON:-}" ]]; then
    _sl_config_degraded python3_unresolvable \
        "no Python 3 could be resolved (tried python3, python, py -3), so lib/paths.py never ran; every path below comes from the bash fallback and may not be the store paths.py would resolve"
fi

if [[ -f "$_sl_paths_py" && -n "${SL_PYTHON:-}" ]]; then
    # Stdout is captured, not piped through a process substitution, so the
    # spawn's EXIT STATUS is available -- it was `2>/dev/null` on a process
    # substitution before, which discarded both the status and the reason on
    # the single most important spawn in the project (rule 2 violation: the
    # store silently moved to the fallback location with nothing recorded).
    # Stderr is folded into the same capture rather than costing a second
    # spawn: the parse loop below only reacts to lines whose key matches one
    # of the eight it knows, so a diagnostic line is inert as input while
    # still being available, verbatim, as the reason in the failure log.
    _sl_paths_rc=0
    _sl_paths_out="$("${SL_PYTHON}" "$_sl_paths_py" all 2>&1)" || _sl_paths_rc=$?
    while IFS='=' read -r _k _v; do
        # Fix round E, defence in depth: paths.py's own stdout now forces LF
        # line endings (see its _main docstring) so this trailing-\r strip
        # should be a no-op in practice -- kept anyway as a second, cheap
        # layer, since `read` only ever strips the record-terminating \n,
        # never a \r immediately before it, and a stray \r silently
        # corrupts every path built from it (a directory named "logs\r" is
        # not "logs").
        _v="${_v%$'\r'}"
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
    done <<< "$_sl_paths_out"
    if [[ "$_sl_paths_rc" -ne 0 || -z "$_sl_pp_home" ]]; then
        _sl_config_degraded paths_resolution_degraded \
            "lib/paths.py could not be run (exit ${_sl_paths_rc}) via ${SL_PYTHON}; falling back to the bash-side mirror at ${_sl_fallback_home}, which may not be the store paths.py resolves. Output: ${_sl_paths_out//$'\n'/ }"
    fi
fi

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

# Cost ceiling for the Copilot reviewer.
#
# AMENDED 2026-07-31: this was EMPTY (unlimited) by deliberate choice; it now
# ships as 30, the CLI's documented minimum. Set it to empty to restore
# unlimited. A silent-failure pipeline with no spend ceiling is worse than a
# truncated review: the review is detached, so an unbounded loop's only symptom
# is the bill. The old reasoning below is kept because its second bullet is the
# real cost of this amendment -- on a Copilot CLI too old to know the flag, the
# review now hard-fails until the operator sets this to empty. That failure is
# LOUD (persist-failures.log, doctor.sh) whereas unbounded spend was silent.
#
# Original reasoning, retained:
#
#  * The knob is real. `copilot help limits` on 1.0.75 documents
#    `--max-ai-credits <credits>`, "Minimum: 30 AI credits", and a
#    prior round's claim that the flag does not exist was wrong.
#  * But `copilot` errors on unknown options (verified: an unknown flag
#    produces "error: unknown option"). Passing --max-ai-credits
#    unconditionally would therefore hard-break the entire review on any
#    Copilot CLI older than the release that added it -- and the review
#    runs in a DETACHED pipeline, so the only symptom would be lines in
#    persist-failures.log while learning quietly stopped. That is a worse
#    failure than the one a default ceiling would prevent.
#  * The cap is a soft cap on GitHub's side (usage is known only after a
#    response returns), so it bounds runaway loops, not individual calls.
#
# Set it to bound a background loop on a machine whose CLI supports it;
# 30 is the minimum the CLI accepts and anything lower is rejected by
# `copilot` itself, so this validates the value before it reaches argv.
SL_COPILOT_MAX_AI_CREDITS="${SL_COPILOT_MAX_AI_CREDITS-30}"

# Which CLI reviews a VS Code Copilot Chat session. VS Code Copilot Chat has
# no headless CLI of its own, so the review has to run in one of the two
# this project already drives. Empty = auto-detect, preferring `copilot`
# (a VS Code Copilot Chat user has a Copilot entitlement by construction,
# and the transcript being reviewed is Copilot's own) then `claude`. Only
# those two literals are accepted; vscode-session-review.sh rejects anything
# else with a reason on stderr rather than passing it to argv.
SL_VSCODE_REVIEWER="${SL_VSCODE_REVIEWER:-}"
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
       SL_COPILOT_MAX_AI_CREDITS SL_VSCODE_REVIEWER \
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
    # M13: grep -qF against "${scripts_dir}/${script_name}" alone is an
    # UNANCHORED substring match, so a hook pointing at
    # ".../turn-counter.sh.bak" (or any other filename that merely starts
    # with the resolved scripts_dir/script_name string) read as "fresh" --
    # the check never verified where the match ENDED. Require the match to
    # be followed by a non-filename character (quote, whitespace, or end of
    # line) so a longer filename sharing the same prefix cannot pass as an
    # exact one. grep -E (not -F) is required for this, so the literal path
    # is regex-escaped first.
    if [[ -n "$scripts_dir" ]]; then
        local full_path escaped
        full_path="${scripts_dir%/}/${script_name}"
        escaped="$(printf '%s' "$full_path" | sed 's/[.[\*^$()+?{|\\]/\\&/g')"
        if grep -qE -- "${escaped}([^A-Za-z0-9_./-]|\$)" "$file" 2>/dev/null; then
            echo "fresh"
            return 0
        fi
    fi
    echo "stale"
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
# The python3 fallback now shells out to lib/isotime.py's `parse` subcommand
# (fix round D, blocker (a)) rather than embedding its own inline `python3
# -c '...'` copy of the same parser. skill-lifecycle.py used to carry an
# independent third copy of exactly this logic, missing both the "Z" swap
# (Python 3.9's fromisoformat rejects a trailing "Z" outright, so every
# shell-producer timestamp -- always written with "Z" -- silently failed to
# parse under 3.9) and the naive-datetime-as-UTC guard (a tz-naive timestamp
# would otherwise be interpreted in the interpreter's local time, silently
# shifting the result). lib/isotime.py is now the single place either fix
# may live; a second inline copy here would be exactly how that defect
# happened the first time. isotime.py's parse_iso() correctly preserves the
# sign of a negative offset (deferred minor 7: a prior strptime-based
# approach could not represent an offset at all, and a naive hand-rolled
# parser is exactly the kind of code that silently flips "-05:00" to
# "+05:00"; fromisoformat parses the sign itself, so there is no such step
# to get wrong).
sl_iso_to_epoch() {
    local ts="$1" epoch
    if [[ -z "$ts" ]]; then
        echo 0
        return 0
    fi
    epoch=$(date -u -d "$ts" +%s 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    epoch=$("${SL_PYTHON}" "$_sl_isotime_py" parse "$ts" 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    echo 0
}
