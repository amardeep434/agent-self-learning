#!/usr/bin/env bash
# lib/store-lock.sh -- bash access to the SAME store lock Python takes.
#
# The lock itself lives in lib/store_lock.py (backend probing, timeout,
# stale handling, crash release). This file is a thin bash front end, the
# same shape lib/skill-layout.sh gives lib/skill_layout.py: one definition,
# two languages, no chance of the two disagreeing about the lock file's
# location or the timeout.
#
# There is deliberately NO acquire/release pair exposed to bash. A held
# lock plus `set -euo pipefail` plus an early `exit` is a leaked lock
# waiting to happen, and bash has no `finally`. Instead the command to be
# protected is passed to `store_lock.py run`, which holds the lock for
# exactly that child's lifetime and releases it when the wrapper exits --
# including if the child is killed.
#
# COST: one python3 spawn per protected span. That is acceptable HERE and
# only here: the sole bash caller is curator-run.sh, which runs from a
# 7-day cron behind a 2-hour idle gate. It is NOT on turn-counter.sh's
# per-tool-call path -- verified, not assumed: `grep -n store-lock.sh
# scripts/*.sh` names curator-run.sh alone, and turn-counter.sh sources only
# lib/config.sh, lib/hook-input.sh and lib/stdin-safe.sh.
#
# Exit codes from the wrapper (see store_lock.py's `run`):
#   75  lock timeout   -- contended; also logged to persist-failures.log
#   74  lock unavailable (e.g. unwritable state dir); also logged
#   *   whatever the protected command itself returned

# One resolver for the interpreter (scripts/lib/python-resolve.sh): `python3`
# is a name real Windows Python installs never provide. Sourced here, not
# assumed from config.sh, because this file is also sourced directly (by its
# own suite). Re-resolution is free once SL_PYTHON is exported.
# shellcheck source=scripts/lib/python-resolve.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/python-resolve.sh"
sl_resolve_python || true

# sl_with_store_lock <cmd> [args...]
#
# Runs <cmd> holding the store lock. Uses $SL_STATE_DIR when set (config.sh
# exports it) so bash and Python resolve the identical lock file; falls back
# to store_lock.py's own resolver otherwise.
sl_with_store_lock() {
    local lib_dir="${_SL_STORE_LOCK_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local -a state_args=()
    if [[ -n "${SL_STATE_DIR:-}" ]]; then
        state_args=(--state-dir "${SL_STATE_DIR}")
    fi
    "${SL_PYTHON}" "${lib_dir}/store_lock.py" run "${state_args[@]}" -- "$@"
}

# sl_store_lock_backend
# Prints the backend store_lock.py's functional probe selected here
# (flock|msvcrt|exclusive), or "unknown" if it could not be probed.
sl_store_lock_backend() {
    local lib_dir="${_SL_STORE_LOCK_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    "${SL_PYTHON}" "${lib_dir}/store_lock.py" backend 2>/dev/null || echo "unknown"
}
