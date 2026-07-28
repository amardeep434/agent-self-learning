#!/usr/bin/env bash
# scripts/skillopt-run.sh — opt-in wrapper around SkillOpt's Sleep CLI.
# File-based only; does NOT use SkillOpt's MCP server (org policy disables MCP).
#
# Two ways in, in UPSTREAM's own precedence order (microsoft/SkillOpt @ 374c832,
# plugins/README.md: "The shared run-sleep.sh supports both source checkouts and
# installed packages. If it cannot find the repository, it tries the
# `skillopt-sleep` executable on PATH"):
#
#   1. A source checkout -- ${SL_SKILLOPT_REPO}/plugins/run-sleep.sh.
#   2. The `skillopt-sleep` executable on PATH (`pip install skillopt`,
#      `uv tool install skillopt`, pipx).
#
# The checkout is tried FIRST, and not merely for symmetry with upstream: a
# checkout of `main` can be AHEAD of the published package. Upstream's own
# version note says PyPI 0.2.0 provides only the base commands, while Sleep
# handoff, Cursor support and `--preferences` require a source install from
# `main`. So when a user has gone to the trouble of cloning, that clone is the
# more capable of the two and must win. Requiring the clone -- as this wrapper
# originally did -- silently gave a `pip install skillopt` user nothing at all.
#
# Upstream's run-sleep.sh has a THIRD fallback: `python -m skillopt_sleep`,
# for an install that is importable but whose console script is not on PATH.
# Not reproduced here. `pip install skillopt` and `uv tool install skillopt`
# both put `skillopt-sleep` on PATH, so route 2 already covers every install
# upstream's own docs tell a user to perform; reproducing the third would mean
# this wrapper carrying its own copy of upstream's "find a Python >= 3.10 and
# probe it for importability" loop, which is exactly the duplicated-logic drift
# this project's CLAUDE.md flags as its most recurring defect class.
#
# Exit behavior: the guard paths (disabled, nothing installed, un-confirmed
# `run`) all exit 0 so they never break a caller. The final passthrough execs
# the SkillOpt runner and therefore returns the runner's OWN exit code —
# callers that require a guaranteed 0 (e.g. a hook) must invoke this with a
# trailing `|| true`.
#
# Usage: skillopt-run.sh <status|harvest|dry-run|run|adopt> [args...]

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck disable=SC1091
source "${LIB_DIR}/config.sh"

if [[ "${SL_SKILLOPT_ENABLED}" != "true" ]]; then
    # Quote the ACTUAL value. The previous message hardcoded
    # "SL_SKILLOPT_ENABLED=false", so `SL_SKILLOPT_ENABLED=1` -- a perfectly
    # reasonable thing for a user to try -- was told a flat untruth about the
    # value it had just been given, with no hint that only "true" is accepted.
    echo "skillopt: disabled (SL_SKILLOPT_ENABLED='${SL_SKILLOPT_ENABLED}'; only the exact value 'true' enables it)" >&2
    exit 0
fi

# --- Route 1: a source checkout -------------------------------------------
# Each way this can go wrong gets its OWN message naming the offending value.
# Previously an unset SL_SKILLOPT_REPO, a path that does not exist, and a path
# pointing one directory off produced a byte-identical sentence, so the message
# could not tell the user which of three quite different mistakes they had made.
RUNNER=""
if [[ -n "${SL_SKILLOPT_REPO}" ]]; then
    CANDIDATE="${SL_SKILLOPT_REPO}/plugins/run-sleep.sh"
    if [[ -f "${CANDIDATE}" ]]; then
        RUNNER="${CANDIDATE}"
    elif [[ ! -e "${SL_SKILLOPT_REPO}" ]]; then
        echo "skillopt: SL_SKILLOPT_REPO='${SL_SKILLOPT_REPO}' does not exist." >&2
    elif [[ ! -d "${SL_SKILLOPT_REPO}" ]]; then
        echo "skillopt: SL_SKILLOPT_REPO='${SL_SKILLOPT_REPO}' is not a directory." >&2
    else
        echo "skillopt: SL_SKILLOPT_REPO='${SL_SKILLOPT_REPO}' has no plugins/run-sleep.sh" >&2
        echo "          (looked for '${CANDIDATE}') — point it at the repository ROOT," >&2
        echo "          not at plugins/ or a subdirectory." >&2
    fi
fi

# --- Route 2: the installed `skillopt-sleep` CLI ---------------------------
if [[ -z "${RUNNER}" ]]; then
    SKILLOPT_CLI="$(command -v skillopt-sleep 2>/dev/null || true)"
    if [[ -z "${SKILLOPT_CLI}" ]]; then
        if [[ -z "${SL_SKILLOPT_REPO}" ]]; then
            echo "skillopt: SL_SKILLOPT_REPO is unset and no 'skillopt-sleep' on PATH." >&2
        else
            echo "skillopt: no usable checkout (see above) and no 'skillopt-sleep' on PATH." >&2
        fi
        echo "          Install one: 'pip install skillopt' (or 'uv tool install skillopt')," >&2
        echo "          or set SL_SKILLOPT_REPO to a clone of microsoft/SkillOpt. Skipping." >&2
        exit 0
    fi
fi

SUBCMD="${1:-status}"
if [[ "${SUBCMD}" == "run" && "${SL_SKILLOPT_RUN_CONFIRMED}" != "true" ]]; then
    echo "skillopt: 'run' blocked — set SL_SKILLOPT_RUN_CONFIRMED=true after reviewing dry-run cost" >&2
    exit 0
fi

if [[ -n "${RUNNER}" ]]; then
    exec bash "${RUNNER}" "$@"
fi
exec "${SKILLOPT_CLI}" "$@"
