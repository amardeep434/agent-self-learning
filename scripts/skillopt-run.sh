#!/usr/bin/env bash
# scripts/skillopt-run.sh — opt-in wrapper around SkillOpt's run-sleep.sh CLI.
# File-based only; does NOT use SkillOpt's MCP server (org policy disables MCP).
#
# Exit behavior: the guard paths (disabled, missing checkout, un-confirmed `run`)
# all exit 0 so they never break a caller. The final passthrough exec'd the
# SkillOpt runner and therefore returns the runner's OWN exit code — callers that
# require a guaranteed 0 (e.g. a hook) must invoke this with a trailing `|| true`.
#
# Usage: skillopt-run.sh <status|harvest|dry-run|run|adopt> [args...]

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck disable=SC1091
source "${LIB_DIR}/config.sh"

if [[ "${SL_SKILLOPT_ENABLED}" != "true" ]]; then
    echo "skillopt: disabled (SL_SKILLOPT_ENABLED=false)" >&2
    exit 0
fi

RUNNER="${SL_SKILLOPT_REPO}/plugins/run-sleep.sh"
if [[ -z "${SL_SKILLOPT_REPO}" || ! -f "${RUNNER}" ]]; then
    echo "skillopt: no SkillOpt checkout found. Set SL_SKILLOPT_REPO to a clone of" >&2
    echo "          microsoft/SkillOpt (must contain plugins/run-sleep.sh). Skipping." >&2
    exit 0
fi

SUBCMD="${1:-status}"
if [[ "${SUBCMD}" == "run" && "${SL_SKILLOPT_RUN_CONFIRMED}" != "true" ]]; then
    echo "skillopt: 'run' blocked — set SL_SKILLOPT_RUN_CONFIRMED=true after reviewing dry-run cost" >&2
    exit 0
fi

exec bash "${RUNNER}" "$@"
