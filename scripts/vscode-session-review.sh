#!/usr/bin/env bash
# scripts/vscode-session-review.sh
#
# VS Code Copilot Chat `Stop` hook: spawn a detached headless review of the
# session so far, and let persist-proposal.py -- never the reviewer -- write
# anything.
#
# Registered by adding the rendered config/vscode-hooks.json to VS Code's
# `chat.hookFilesLocations`. See install.sh's Step 4c and README.md.
#
# Three things about this harness that shape the script, all MEASURED in the
# 2026-07-28 spike (VS Code 1.130.0 / GitHub.copilot-chat 0.58.0, Linux --
# see docs/superpowers/vscode-adapter-spike.md):
#
#  1. The payload arrives as JSON on STDIN (11/11 invocations; argv empty
#     11/11), in Claude Code's field shape -- `session_id`,
#     `hook_event_name`, `cwd`, `transcript_path`. lib/hook-input.sh already
#     parses exactly those, unchanged.
#  2. `Stop` fires PER TURN, not per session (3 prompts produced 3 `Stop`s).
#     The docs' "Agent session ends" wording is misleading. Everything about
#     cost in this script follows from that: an ungated review here would be
#     one paid model call per user turn.
#  3. `transcript_path` is present AND the file already exists when the hook
#     runs (11/11), so there is no path discovery and no wait-for-file race.
#     The file uses Copilot CLI's event vocabulary, which
#     lib/transcript.py's summarize_events already reads -- verified live
#     (28 events -> 8 messages, 5 -> 2, unknown_shapes={} both times).
#
# The transcript format is documented by VS Code as explicitly NOT a stable
# API, and the hook feature itself is Preview. The unknown-shape canary in
# summarize_events is what turns a format change into a persist-failures.log
# line rather than a silently halved digest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Recursion guard: a spawned reviewer's own hooks must not re-trigger review.
if [[ -n "${SL_REVIEW_ACTIVE:-}" ]]; then
    exit 0
fi

# shellcheck disable=SC1091
source "${LIB_DIR}/config.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/hook-input.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/review-common.sh"

STATE_DIR="${SL_STATE_DIR}"
COUNTER_FILE="${STATE_DIR}/turn_counter.json"
REVIEW_ENABLED="${SL_REVIEW_ENABLED:-true}"
MIN_TURNS_FOR_REVIEW="${SL_REVIEW_MIN_TURNS}"
LOG_DIR="${SL_LOG_DIR}/reviews"

if [[ "$REVIEW_ENABLED" != "true" ]]; then
    exit 0
fi

mkdir -p "$LOG_DIR"

# --- Turn gate ---
# Identical to session-review.sh's, and load-bearing for a different reason:
# because `Stop` is per TURN here, without this gate every single user turn
# would spawn a paid review. turn-counter.sh (registered on PostToolUse by
# config/vscode-hooks.json) is what advances the counter; VS Code fires
# PostToolUse and ignores matcher values, so it counts every tool call.
#
# Known, accepted consequence: an ask-only turn produces no PostToolUse
# (measured -- a no-tool prompt fired `UserPromptSubmit -> Stop` with no
# `PostToolUse`), so a purely conversational VS Code session never reaches
# the gate and is never reviewed. That errs toward under-reviewing rather
# than toward burning calls, which is the right direction for a per-turn
# event, and it is documented rather than hidden.
if [[ ! -f "$COUNTER_FILE" ]]; then
    exit 0
fi

TOTAL_TURNS=$(jq -r '.total_turns_this_session // 0' "$COUNTER_FILE" 2>/dev/null || echo "0")
if (( TOTAL_TURNS < MIN_TURNS_FOR_REVIEW )); then
    exit 0
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Resolve the session transcript ---
# --harness auto rather than --harness vscode, deliberately. This script is
# reached through a user-editable `chat.hookFilesLocations` entry, and the
# ADJACENT registration path (~/.claude/settings.json, which VS Code reads by
# default) can put a Claude Code transcript in front of a VS Code-registered
# hook and vice versa. Sniffing the file settles which parser is correct
# from the file itself instead of from an assumption about who called us;
# the two payloads carry the same field names and the same event name, so
# there is nothing else to go on. See detect_transcript_format.
# --component, because --harness auto would otherwise attribute this
# script's failures to session-review.sh and send a reader to the wrong file.
TRANSCRIPT_DIGEST="$(python3 "${LIB_DIR}/transcript.py" --harness auto "${HOOK_TRANSCRIPT_PATH}" \
    --component vscode-session-review \
    --log-file "${SL_LOG_DIR}/persist-failures.log" \
    2>>"${LOG_DIR}/transcript.err" || true)"

# --- No digest, no review ---
# This is where this script deliberately DIFFERS from session-review.sh,
# which spawns its reviewer even when the transcript could not be read.
#
# That asymmetry is about cadence, not taste. Claude Code's `Stop` is once
# per session, so a transcript failure there costs one wasted call and the
# reviewer can still act on MEMORY.md/USER.md context. VS Code's `Stop` is
# once per TURN, so the identical behaviour here would be a paid model call
# with an empty transcript on every turn, forever, plus one
# persist-failures.log line each -- which is both the cost defect and the
# "train the user to ignore the only failure channel" defect this branch
# exists to fix.
#
# Not silent: transcript.py has already written the reason to
# persist-failures.log (doctor.sh surfaces it) before we get here. This
# refuses to SPEND on nothing; it does not hide that nothing happened.
if [[ -z "${TRANSCRIPT_DIGEST}" ]]; then
    exit 0
fi

REVIEW_PROMPT="$(cat <<RPEOF
You are a Background Review agent performing an end-of-session review of a
VS Code Copilot Chat session. Read ${SL_MEMORY_DIR}/MEMORY.md,
${SL_MEMORY_DIR}/USER.md, and scan ${SL_SKILLS_DIR}/ for existing skills.

## Task: Combined Review
1. Memory review: extract user corrections, project facts, and preferences
   from this session. Write single-line entries (max 120 chars) to MEMORY.md
   or USER.md.
2. Skill review: extract reusable patterns/workflows as skills. Each
   proposed skill is persisted (by the writer, not by you) as
   ${SL_SKILLS_DIR}/<skill-name>/SKILL.md. Prefer updating existing skills.

## Rules
- Maximum 3 memory writes + 2 skill operations.
- Never save secrets, tokens, API keys, passwords, or personal data.
- Skill names must match [A-Za-z0-9][A-Za-z0-9_-]{0,63} (max 64 chars,
  case-sensitive, digits/letters/underscore/hyphen only -- no dots); skill
  descriptions max 60 chars, one sentence, ending with a period.
- Only read files under ${SL_MEMORY_DIR} and ${SL_SKILLS_DIR}.
- No network requests. No package installs.
RPEOF
)"

# The three shared sections, from lib/review-common.sh -- the same single
# copy session-review.sh and copilot-session-review.sh use. Adding a third
# pasted copy of this text is precisely what that library exists to prevent.
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_output_contract)"
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_transcript_section "${TRANSCRIPT_DIGEST}")"
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_coach_section)"

# --- Pick a reviewer CLI ---
# VS Code Copilot Chat has no headless CLI of its own to run the review in,
# so the reviewer has to be one of the two CLIs this project already drives.
# Order: `copilot` first, because a VS Code Copilot Chat user has a Copilot
# entitlement by construction and the transcript being reviewed is Copilot's
# own; `claude` second. SL_VSCODE_REVIEWER overrides, and is validated
# against that closed set rather than being passed through to a shell -- it
# reaches argv.
SL_VSCODE_REVIEWER="${SL_VSCODE_REVIEWER:-}"
REVIEWER=""
if [[ -n "${SL_VSCODE_REVIEWER}" ]]; then
    case "${SL_VSCODE_REVIEWER}" in
        copilot|claude)
            if command -v "${SL_VSCODE_REVIEWER}" &>/dev/null; then
                REVIEWER="${SL_VSCODE_REVIEWER}"
            fi
            ;;
        *)
            echo "vscode-session-review: ignoring invalid SL_VSCODE_REVIEWER='${SL_VSCODE_REVIEWER}' (must be 'copilot' or 'claude')" >&2
            ;;
    esac
fi
if [[ -z "$REVIEWER" ]]; then
    for candidate in copilot claude; do
        if command -v "$candidate" &>/dev/null; then
            REVIEWER="$candidate"
            break
        fi
    done
fi

# Never exit 0 having quietly done nothing: `if command -v X; then ... fi`
# with no else branch is this project's signature defect wearing a shell
# idiom. A machine with neither CLI installed must say so in the one channel
# doctor.sh reads.
if [[ -z "$REVIEWER" ]]; then
    sl_review_no_reviewer_available vscode-session-review "$SL_LOG_DIR" copilot claude
    exit 0
fi

if [[ "$REVIEWER" == "copilot" ]]; then
    # Same flags as copilot-session-review.sh: headless, read-only. No write
    # tool -- the reviewer proposes, persist-proposal.py persists.
    sl_review_launch_detached vscode-session-review vscode-review-stderr.log \
        "$SL_LOG_DIR" "${SCRIPT_DIR}/persist-proposal.py" \
        copilot -s --allow-tool read -p "$REVIEW_PROMPT"
else
    # Same flags as session-review.sh, including the deny list that makes the
    # no-writes constraint hold independently of the host's settings.json.
    sl_review_launch_detached vscode-session-review vscode-review-stderr.log \
        "$SL_LOG_DIR" "${SCRIPT_DIR}/persist-proposal.py" \
        claude -p "$REVIEW_PROMPT" --max-turns "${SL_REVIEW_MAX_TURNS}" \
        --output-format text \
        --allowedTools "Read,Glob,Grep" \
        --disallowedTools "Write,Edit,NotebookEdit"
fi

# --- Update counter state ---
# session-review.sh's bookkeeping PLUS `total_turns_this_session = 0`, and
# that addition is not cosmetic. session-review.sh can leave the total
# standing because Claude Code's `Stop` fires once per session and
# turn-counter.sh zeroes the total itself on the next session-id change.
# Here `Stop` fires every turn against the SAME session id, so leaving the
# total above SL_REVIEW_MIN_TURNS would re-arm the gate on the very next
# turn and spawn a review per turn from then on -- the exact cost blow-up
# the gate exists to prevent. Resetting it makes the gate mean "every N
# tool calls", which is the only reading that makes sense for a per-turn
# event.
jq --arg now "$NOW" \
    '.last_review_at = $now | .memory_turns = 0 | .skill_iterations = 0 | .total_turns_this_session = 0' \
    "$COUNTER_FILE" > "${COUNTER_FILE}.tmp" \
    && mv "${COUNTER_FILE}.tmp" "$COUNTER_FILE"

rm -f "${STATE_DIR}/review_signal.json"
echo "$NOW" > "${STATE_DIR}/last-session-end"

exit 0
