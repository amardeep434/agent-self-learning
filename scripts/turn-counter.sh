#!/usr/bin/env bash
#
# Turn counter for Background Review system.
# Called as a PostToolUse hook after EVERY tool use.
#
# Responsibilities (all of them now live in lib/turn_counter_core.py):
# 1. Increment the skill_iterations counter (every tool call)
# 2. Detect assistant responses and increment memory_turns
# 3. Write a signal file when either threshold is reached
# 4. Handle session boundary detection (reset on new session)
#
# Input: hook payload JSON on stdin (session_id, tool_name, ...), passed
# straight through to the core on ITS stdin.
# Configuration: scripts/lib/config.sh (env > $SL_HOME/self-learning.conf > defaults).
#
# Performance target: <100ms. Two Python spawns per fire -- config.sh's
# `lib/paths.py all` path resolution, and the core below -- plus the one
# `--version` probe lib/python-resolve.sh uses to identify the interpreter.
# jq is GONE: it was this project's last runtime dependency and existed for
# exactly one JSON read on this path, which meant telling every Windows user
# to install a second tool for it. Note the shape of the fix: an earlier
# attempt swapped `jq` for `lib/jsonio.py` and was reverted because it ADDED a
# spawn (measured 97-129ms against this budget). Consolidating the payload
# read, the state read and both writes into the ONE process this hook already
# pays for removes spawns instead of adding them. See CLAUDE.md's hook-budget
# bullet for the measurements and for why caching path resolution was
# considered and rejected.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

# Recursion guard: never count tool calls made by a spawned background reviewer.
if [[ -n "${SL_REVIEW_ACTIVE:-}" ]]; then
    exit 0
fi

# shellcheck disable=SC1091
source "${LIB_DIR}/config.sh"

# No interpreter, nothing to run. Deliberately NOT reported here: config.sh
# has already written a throttled, named `python3_unresolvable` line to
# persist-failures.log (the one channel doctor.sh reads) on this very source
# above. A second line from this hook would say the same thing about the same
# cause on every tool use, against the same log whose readability the
# throttle exists to protect.
if [[ -z "${SL_PYTHON:-}" ]]; then
    exit 0
fi

# `exec`: the core inherits this hook's stdin (the payload) and its exit
# status IS the hook's. The core exits 0 on every path by design -- a
# PostToolUse hook that exits nonzero is noise in the user's session, and its
# failure channel is persist-failures.log, not a status nobody reads.
exec "${SL_PYTHON}" "${LIB_DIR}/turn_counter_core.py" \
    --counter-file    "${SL_STATE_DIR}/turn_counter.json" \
    --signal-file     "${SL_STATE_DIR}/review_signal.json" \
    --lock-dir        "${SL_STATE_DIR}/counter.lock" \
    --degraded-marker "${SL_STATE_DIR}/.counter-degraded" \
    --log-dir         "${SL_LOG_DIR}" \
    --memory-interval "${SL_MEMORY_REVIEW_INTERVAL}" \
    --skill-interval  "${SL_SKILL_REVIEW_INTERVAL}"
