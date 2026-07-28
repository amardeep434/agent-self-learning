#!/usr/bin/env bash
# scripts/copilot-session-review.sh
#
# Copilot CLI sessionEnd hook: spawn a detached headless Copilot review that
# writes memories/skills to the shared self-learning stores.
#
# Registered via ~/.copilot/hooks/self-learning.json (template: config/copilot-hooks.json).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Recursion guard: the spawned reviewer's own sessionEnd must not re-trigger.
if [[ -n "${SL_REVIEW_ACTIVE:-}" ]]; then
    exit 0
fi

# shellcheck disable=SC1091
source "${LIB_DIR}/config.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/copilot-hook-input.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/review-common.sh"

LOG_DIR="${SL_LOG_DIR}/reviews"
mkdir -p "$LOG_DIR"

# --- Resolve the session transcript from the sessionEnd payload's sessionId ---
# Without this, the reviewer spawned below is asked to review a session it
# has zero information about -- see scripts/lib/transcript.py's module
# docstring. A missing/empty/unparseable transcript for a session that DID
# converse is logged to persist-failures.log (doctor.sh surfaces it), never
# silently swallowed.
#
# fix-empty-session: a session that never took a turn is a different thing
# entirely. `sessionEnd` fires for those too, and on the machine this was
# found on they were ~53% of all sessions (95 of 179). Routing them into
# persist-failures.log made a healthy store read UNHEALTHY and devalued the
# one channel a genuinely broken detached review can reach. transcript.py
# now classifies them separately, records them in persist.log as a skipped
# outcome, and exits EXIT_NO_CONVERSATION (20). Note the failure path below
# is deliberately UNCHANGED -- a real transcript failure still logs loudly
# AND still spawns the review; only the provably-empty case short-circuits.
TRANSCRIPT_STATUS=0
TRANSCRIPT_DIGEST="$(python3 "${LIB_DIR}/transcript.py" "${COPILOT_HOOK_SESSION_ID}" \
    --log-file "${SL_LOG_DIR}/persist-failures.log" \
    --notice-log "${SL_LOG_DIR}/persist.log" \
    2>>"${LOG_DIR}/transcript.err")" || TRANSCRIPT_STATUS=$?

# Nothing was said, so there is provably nothing to learn: skip the paid
# model call rather than spend one reviewing an empty session. The
# persist.log line written above is what keeps this distinguishable from
# "the hook never ran", which leaves no line anywhere.
if [[ "${TRANSCRIPT_STATUS}" -eq 20 ]]; then
    exit 0
fi

REVIEW_PROMPT="$(cat <<RPEOF
You are a Background Review agent performing an end-of-session review.
Read ${SL_MEMORY_DIR}/MEMORY.md, ${SL_MEMORY_DIR}/USER.md, and scan
${SL_SKILLS_DIR}/ for existing skills.

## Task: Combined Review
1. Memory review: extract user corrections, project facts, and preferences
   from this session. Write single-line entries (max 120 chars) to MEMORY.md
   or USER.md.
2. Skill review: extract reusable patterns/workflows as skills. Each
   proposed skill is persisted (by the writer, not by you) as
   ${SL_SKILLS_DIR}/<skill-name>/SKILL.md. Prefer updating existing skills.

## Rules
- Maximum 3 new memory FACTS + 2 skill operations. Those facts go into at
  most one JSON entry per memory file -- see the OUTPUT CONTRACT below.
- Never save secrets, tokens, API keys, passwords, or personal data.
- Skill names must match [A-Za-z0-9][A-Za-z0-9_-]{0,63} (max 64 chars,
  case-sensitive, digits/letters/underscore/hyphen only -- no dots); skill
  descriptions max 60 chars, one sentence, ending with a period.
- Only read files under ${SL_MEMORY_DIR} and ${SL_SKILLS_DIR}.
- No network requests. No package installs.
RPEOF
)"

# Shared with session-review.sh and vscode-session-review.sh via
# lib/review-common.sh -- these three blocks were byte-identical across the
# adapters before the extraction (verified with `diff`), and a third paste
# was not an option. Only the harness-specific preamble above stays inline.
# This path passes no Coach trailer; the Claude Code path does.
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_output_contract)"
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_transcript_section "${TRANSCRIPT_DIGEST}")"
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_coach_section)"

# No --allow-tool write: the reviewer proposes, this script persists. Copilot
# CLI's path allow-list refused writes to the store, which made this loop a
# silent no-op; removing the write tool removes the dependency entirely.
COPILOT_ARGS=(-s --allow-tool read)
if [[ -n "${SL_COPILOT_REVIEW_MODEL}" ]]; then
    if [[ "${SL_COPILOT_REVIEW_MODEL}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        COPILOT_ARGS+=(--model "${SL_COPILOT_REVIEW_MODEL}")
    else
        echo "copilot-session-review: ignoring invalid SL_COPILOT_REVIEW_MODEL" >&2
    fi
fi

# Optional cost ceiling. Same shape as the model knob above -- validated
# here, never interpolated blind -- because this value also reaches a
# third-party binary's argv.
#
# Off unless explicitly set: see the long note in lib/config.sh for why the
# default is empty rather than the documented minimum. Short version:
# `copilot` errors on unknown options, so an unconditional --max-ai-credits
# would hard-break the whole review on any CLI older than the release that
# added the flag, and this pipeline is detached, so that break would show up
# only as persist-failures.log lines while learning silently stopped.
#
# The <30 rejection is not us second-guessing the CLI: `copilot
# --max-ai-credits 5` exits with "Use at least 30 AI credits", which in the
# detached pipeline would be an unexplained non-zero. Refusing it here with
# a named reason on stderr is the same "fail where a human can read it"
# discipline the rest of this script follows.
if [[ -n "${SL_COPILOT_MAX_AI_CREDITS}" ]]; then
    if [[ "${SL_COPILOT_MAX_AI_CREDITS}" =~ ^[0-9]+$ ]] && (( SL_COPILOT_MAX_AI_CREDITS >= 30 )); then
        COPILOT_ARGS+=(--max-ai-credits "${SL_COPILOT_MAX_AI_CREDITS}")
    else
        echo "copilot-session-review: ignoring SL_COPILOT_MAX_AI_CREDITS='${SL_COPILOT_MAX_AI_CREDITS}' (must be an integer >= 30, the minimum the CLI accepts)" >&2
    fi
fi

# Entire pipeline detached, for the same reason as the Claude Code path: a
# review outlives the sessionEnd hook's timeout. The detaching, the
# positional argument passing, the failure log and the completion marker are
# lib/review-common.sh's sl_review_launch_detached -- see its header. Note
# `-p "$prompt"` comes LAST here, after the variable-length COPILOT_ARGS,
# exactly as before.
if command -v copilot &>/dev/null; then
    sl_review_launch_detached copilot-session-review copilot-review-stderr.log \
        "$SL_LOG_DIR" "${SCRIPT_DIR}/persist-proposal.py" \
        copilot "${COPILOT_ARGS[@]}" -p "$REVIEW_PROMPT"
else
    # See the identical else branch in session-review.sh: a bare `fi` here
    # means a machine whose copilot CLI is missing or renamed reviews nothing,
    # forever, and says so nowhere.
    sl_review_no_reviewer_available copilot-session-review "$SL_LOG_DIR" copilot
fi

exit 0
