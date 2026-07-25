#!/usr/bin/env bash
# tests/test-install-paths.sh
#
# The teeth of Task 7b: install.sh must never create or depend on ~/.claude.
# Runs install.sh FOR REAL (not --dry-run) under env -i with a temp HOME, an
# explicit AGENT_LEARNING_HOME so the resolved store is fully controlled, and
# a fake ~/.copilot so the Copilot adapter step actually runs instead of
# silently skipping.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

STORE="${TMP_HOME}/store"

# --- Build a minimal, controlled PATH that resolves everything install.sh
# needs (python3, jq, sqlite3, plus the coreutils it shells out to), without
# assuming /usr/bin:/bin is sufficient (pyenv shims, Homebrew, etc. put these
# tools elsewhere). Fail loudly — not silently degrade to a real PATH — if a
# tool cannot be resolved, so a red result here can never be mistaken for a
# real install.sh bug.
_dirs=""
for _tool in mkdir cp chmod sed sqlite3 python3 jq dirname basename date; do
    _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
    if [[ -z "$_tool_path" ]]; then
        echo "FAIL: test setup is wrong — '$_tool' is not resolvable on this machine"
        FAILURES=$((FAILURES+1))
        continue
    fi
    _tool_dir="$(dirname "$_tool_path")"
    case ":${_dirs}:" in
        *":${_tool_dir}:"*) ;;
        *) _dirs="${_dirs:+${_dirs}:}${_tool_dir}" ;;
    esac
done
# pyenv's python3 shim execs back into pyenv's libexec; keep that resolvable.
if [[ -n "${PYENV_ROOT:-}" ]]; then
    _dirs="${_dirs}:${PYENV_ROOT}/libexec:${PYENV_ROOT}/bin"
fi
MINIMAL_PATH="${_dirs}:/usr/bin:/bin"

for _tool in python3 jq sqlite3; do
    if ! PATH="$MINIMAL_PATH" command -v "$_tool" >/dev/null 2>&1; then
        echo "FAIL: test setup is wrong — $_tool is not resolvable on MINIMAL_PATH"
        FAILURES=$((FAILURES+1))
    fi
done
if [[ "$FAILURES" -gt 0 ]]; then
    echo "Aborting: test harness cannot resolve required tools; not a real red result." >&2
    exit 1
fi

# Fake ~/.copilot so the Copilot adapter step actually runs instead of being
# gated out by "directory does not exist" — without this the hook-config
# assertions below would be vacuous.
mkdir -p "${TMP_HOME}/.copilot"

run_install() {
    env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
        AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
        bash "${SCRIPT_DIR}/install.sh" </dev/null
}

INSTALL_STATUS=0
INSTALL_OUT="$(run_install)" || INSTALL_STATUS=$?
check "install.sh exits 0" "0" "$INSTALL_STATUS"

# --- The assertion this task lives or dies by ---
if [[ -e "${TMP_HOME}/.claude" ]]; then
    echo "FAIL: install.sh created ${TMP_HOME}/.claude"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: no \${HOME}/.claude created by a real install"
fi

# --- Installed scripts live under the resolved scripts dir ---
RESOLVED_SCRIPTS="$(env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" AGENT_LEARNING_HOME="$STORE" \
    ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
    python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get scripts)"
check "resolved scripts dir is under the store" "${STORE}/scripts" "$RESOLVED_SCRIPTS"

for s in turn-counter.sh session-review.sh index-session.sh copilot-session-review.sh \
         self-learning-health.sh curator-run.sh; do
    check "installed script exists: $s" "yes" "$([[ -f "${RESOLVED_SCRIPTS}/${s}" ]] && echo yes || echo no)"
done
check "lib/config.sh installed" "yes" "$([[ -f "${RESOLVED_SCRIPTS}/lib/config.sh" ]] && echo yes || echo no)"
check "lib/paths.py installed" "yes" "$([[ -f "${RESOLVED_SCRIPTS}/lib/paths.py" ]] && echo yes || echo no)"

# --- Data directories under the resolved home, not under ~/.claude ---
check "state dir under store" "yes" "$([[ -d "${STORE}/state" ]] && echo yes || echo no)"
check "memory dir under store" "yes" "$([[ -d "${STORE}/memory" ]] && echo yes || echo no)"
check "learned-skills dir under store" "yes" "$([[ -d "${STORE}/learned-skills" ]] && echo yes || echo no)"
check "logs dir under store" "yes" "$([[ -d "${STORE}/logs/reviews" ]] && echo yes || echo no)"
check "sessions db under store" "yes" "$([[ -f "${STORE}/sessions/search.db" ]] && echo yes || echo no)"

# --- The Copilot hook config: rendered, resolved, and verifiably correct ---
COPILOT_HOOK="${TMP_HOME}/.copilot/hooks/self-learning.json"
check "copilot hook config was written" "yes" "$([[ -f "$COPILOT_HOOK" ]] && echo yes || echo no)"

if [[ -f "$COPILOT_HOOK" ]]; then
    HOOK_CONTENT="$(cat "$COPILOT_HOOK")"

    check "hook config contains resolved scripts path" "yes" \
        "$(printf '%s' "$HOOK_CONTENT" | grep -qF "${RESOLVED_SCRIPTS}/copilot-session-review.sh" && echo yes || echo no)"
    check "hook config contains no .claude" "0" \
        "$(printf '%s' "$HOOK_CONTENT" | grep -c '\.claude' || true)"
    check "hook config has no unsubstituted placeholder" "0" \
        "$(printf '%s' "$HOOK_CONTENT" | grep -c '__SL_SCRIPTS_DIR__' || true)"
    check "hook config contains no CLAUDE string" "0" \
        "$(printf '%s' "$HOOK_CONTENT" | grep -c 'CLAUDE' || true)"

    # The path named in the hook config must point at a file that actually
    # exists — a correctly-formed but wrong substitution must fail this.
    HOOK_BASH_CMD="$(jq -r '.hooks.sessionEnd[0].bash' "$COPILOT_HOOK")"
    HOOK_SCRIPT_PATH="${HOOK_BASH_CMD#bash }"
    check "hook-config script path exists on disk" "yes" \
        "$([[ -f "$HOOK_SCRIPT_PATH" ]] && echo yes || echo no)"
    check "hook-config script path equals installed copilot-session-review.sh" \
        "${RESOLVED_SCRIPTS}/copilot-session-review.sh" "$HOOK_SCRIPT_PATH"
fi

# --- Idempotence: re-running must not create ~/.claude either, and must
# still be correct ---
SECOND_STATUS=0
SECOND_OUT="$(run_install)" || SECOND_STATUS=$?
check "second install.sh run exits 0" "0" "$SECOND_STATUS"
if [[ -e "${TMP_HOME}/.claude" ]]; then
    echo "FAIL: second install.sh run created ${TMP_HOME}/.claude"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: second run still creates no \${HOME}/.claude"
fi
check "idempotent: scripts still present after 2nd run" "yes" \
    "$([[ -f "${RESOLVED_SCRIPTS}/turn-counter.sh" ]] && echo yes || echo no)"
check "idempotent: copilot hook config still correct after 2nd run" "yes" \
    "$(grep -qF "${RESOLVED_SCRIPTS}/copilot-session-review.sh" "$COPILOT_HOOK" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- install.sh output (first run) for debugging ---"
    printf '%s\n' "$INSTALL_OUT"
    exit 1
fi
echo "All install-paths tests passed."
