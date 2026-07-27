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
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

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
for _tool in mkdir cp chmod sed grep cat sqlite3 python3 jq dirname basename date; do
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
# Fix round E: compared with sl_check_same_path, not plain string equality
# -- RESOLVED_SCRIPTS crossed a python3.exe subprocess boundary (subject to
# MSYS auto-conversion on Git Bash) while "${STORE}/scripts" never did.
sl_check_same_path "resolved scripts dir is under the store" "${STORE}/scripts" "$RESOLVED_SCRIPTS"

for s in turn-counter.sh session-review.sh index-session.sh copilot-session-review.sh \
         self-learning-health.sh curator-run.sh; do
    check "installed script exists: $s" "yes" "$([[ -f "${RESOLVED_SCRIPTS}/${s}" ]] && echo yes || echo no)"
done
check "lib/config.sh installed" "yes" "$([[ -f "${RESOLVED_SCRIPTS}/lib/config.sh" ]] && echo yes || echo no)"
check "lib/paths.py installed" "yes" "$([[ -f "${RESOLVED_SCRIPTS}/lib/paths.py" ]] && echo yes || echo no)"

# --- Structural guard: install.sh's SCRIPTS array must never silently omit
# a script again. This has happened twice: Task 7b omitted
# lib/proposal_schema.py (an import persist-proposal.py needs, breaking the
# whole persistence path on a real install with no test catching it), and
# Task 9 omitted doctor.sh itself -- the tool whose entire purpose is
# surfacing silent failures was, itself, silently unreachable on any real
# install. Both were caught by a human reading code, not a test. This makes
# it structural: every scripts/*.sh and scripts/*.py must either appear in
# install.sh's SCRIPTS array or be explicitly exempted below with a reason,
# so a new script forces a conscious decision instead of a silent omission.
# No associative arrays here (bash 3.2 on stock macOS lacks them) --
# "name|reason" pairs in a plain indexed array instead.
INSTALL_SCRIPTS_ARRAY="$(sed -n '/^SCRIPTS=(/,/^)/p' "${SCRIPT_DIR}/install.sh" | grep -oE '"[^"]+"' | tr -d '"' || true)"

INSTALL_EXEMPTIONS=(
    "sync-coach-rules.sh|maintainer-only vendoring tool; requires the gh CLI and writes into the repo checkout's vendor/coach-rules/, run from source, never from an installed store"
)

install_exempt_reason() {
    local name="$1" entry
    for entry in "${INSTALL_EXEMPTIONS[@]}"; do
        case "$entry" in
            "${name}|"*) printf '%s' "${entry#*|}"; return 0 ;;
        esac
    done
    return 1
}

for f in "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/scripts/*.py; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if printf '%s\n' "$INSTALL_SCRIPTS_ARRAY" | grep -qxF "$name"; then
        echo "PASS: $name is installed by install.sh"
    elif reason="$(install_exempt_reason "$name")"; then
        echo "PASS: $name is explicitly exempted from install ($reason)"
    else
        echo "FAIL: $name is neither installed by install.sh's SCRIPTS array nor exempted in this test"
        FAILURES=$((FAILURES+1))
    fi
done

# --- Hardcoded expected-file list: the writer and everything it needs to
# import must be installed, or the review pipeline burns a paid model call
# and persists nothing while exiting 0 at the hook level — the exact defect
# this project exists to eliminate, just moved to a new file. Existence
# checks alone cannot prove imports resolve; see the end-to-end assertion
# below for that.
EXPECTED_FILES=(
    "persist-proposal.py"
    "lib/paths.py"
    "lib/proposal_schema.py"
    "lib/isotime.py"
    "lib/config.sh"
    "session-review.sh"
    "copilot-session-review.sh"
)
for f in "${EXPECTED_FILES[@]}"; do
    check "expected installed file present: $f" "yes" \
        "$([[ -f "${RESOLVED_SCRIPTS}/${f}" ]] && echo yes || echo no)"
done

# --- Data directories under the resolved home, not under ~/.claude ---
check "state dir under store" "yes" "$([[ -d "${STORE}/state" ]] && echo yes || echo no)"
check "memory dir under store" "yes" "$([[ -d "${STORE}/memory" ]] && echo yes || echo no)"
check "learned-skills dir under store" "yes" "$([[ -d "${STORE}/learned-skills" ]] && echo yes || echo no)"
check "logs dir under store" "yes" "$([[ -d "${STORE}/logs/reviews" ]] && echo yes || echo no)"
check "sessions db under store" "yes" "$([[ -f "${STORE}/sessions/search.db" ]] && echo yes || echo no)"

# --- I5 regression guard: SL_COACH_RULES_DIR (as lib/config.sh resolves it
# for a real caller) must resolve to a directory that ACTUALLY EXISTS after
# a real install, not just a scripts-array membership check. The prior
# default (.../scripts/self-learning/coach-rules) passed every existing
# assertion here while pointing at a directory install.sh never creates --
# this is exactly the blind spot that let it slip through. Sourcing
# lib/config.sh (as every real consumer does) is the only way to catch a
# future re-drift between install.sh's actual destination and config.sh's
# default, rather than re-deriving install.sh's path a second time here.
SL_COACH_RULES_DIR_RESOLVED="$(env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" AGENT_LEARNING_HOME="$STORE" \
    ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
    bash -c "source '${RESOLVED_SCRIPTS}/lib/config.sh'; echo \"\$SL_COACH_RULES_DIR\"")"
check "SL_COACH_RULES_DIR resolves to a directory that exists after a real install" "yes" \
    "$([[ -d "$SL_COACH_RULES_DIR_RESOLVED" ]] && echo yes || echo no)"
sl_check_same_path "SL_COACH_RULES_DIR resolves under the installed scripts dir (matches install.sh's Step 3b destination)" \
    "${RESOLVED_SCRIPTS}/coach-rules" "$SL_COACH_RULES_DIR_RESOLVED"

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

# --- The Claude Code hook JSON: rendered from the template, and correct in the
# three ways defect A1 was wrong. install.sh used to hand-roll this block in
# echo statements -- flat schema, millisecond timeouts -- so a user who pasted
# the installer's own output registered nothing at all, silently. These
# assertions run against the RENDERED artifact, not the template, because the
# template was already correct when A1 shipped; it was the rendering that lied.
CLAUDE_HOOK_RENDERED="${STORE}/settings-hooks.json"
check "claude hook JSON was rendered to the store" "yes" \
    "$([[ -f "$CLAUDE_HOOK_RENDERED" ]] && echo yes || echo no)"

if [[ -f "$CLAUDE_HOOK_RENDERED" ]]; then
    check "rendered claude hook JSON parses" "yes" \
        "$(jq -e . "$CLAUDE_HOOK_RENDERED" >/dev/null 2>&1 && echo yes || echo no)"
    check "rendered JSON uses the nested hooks[] schema" "yes" \
        "$(jq -e '.hooks.PostToolUse[0].hooks[0].type == "command" and .hooks.Stop[0].hooks[0].type == "command"' \
            "$CLAUDE_HOOK_RENDERED" >/dev/null 2>&1 && echo yes || echo no)"
    check "rendered JSON has no flat-schema command on a matcher group" "0" \
        "$(jq '[.hooks[][] | select(has("command"))] | length' "$CLAUDE_HOOK_RENDERED")"
    check "rendered JSON has no unsubstituted placeholder" "0" \
        "$(grep -c '__SL_SCRIPTS_DIR__' "$CLAUDE_HOOK_RENDERED" || true)"
    check "rendered JSON names no ~/.claude script path" "0" \
        "$(jq -r '.hooks[][].hooks[].command' "$CLAUDE_HOOK_RENDERED" | grep -c '\.claude' || true)"

    RENDERED_ENTRIES="$(jq '[.hooks[][].hooks[]] | length' "$CLAUDE_HOOK_RENDERED")"
    check "rendered JSON timeouts are seconds, not milliseconds (1..600)" "$RENDERED_ENTRIES" \
        "$(jq '[.hooks[][].hooks[] | select(.timeout >= 1 and .timeout <= 600)] | length' "$CLAUDE_HOOK_RENDERED")"

    # The teeth: every path named must be a file this very install created.
    # A correctly-formed but wrong substitution has to fail here.
    while IFS= read -r cmd; do
        hook_script="${cmd#bash }"
        check "rendered hook path exists on disk: $(basename "$hook_script")" "yes" \
            "$([[ -f "$hook_script" ]] && echo yes || echo no)"
        sl_check_same_path "rendered hook path is under the installed scripts dir: $(basename "$hook_script")" \
            "${RESOLVED_SCRIPTS}/$(basename "$hook_script")" "$hook_script"
    done < <(jq -r '.hooks[][].hooks[].command' "$CLAUDE_HOOK_RENDERED")

    # What install.sh PRINTS must be what it wrote -- the printed block is what
    # users actually paste, and a divergence between the two is exactly the
    # two-copies-of-one-definition class A1 belongs to.
    FIRST_PRINTED_CMD="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$CLAUDE_HOOK_RENDERED")"
    check "install.sh printed the rendered turn-counter command" "yes" \
        "$(printf '%s' "$INSTALL_OUT" | grep -qF "$FIRST_PRINTED_CMD" && echo yes || echo no)"
    check "install.sh printed no millisecond timeout" "0" \
        "$(printf '%s' "$INSTALL_OUT" | grep -cE '"timeout": (3000|10000|15000)' || true)"
fi

# --- End-to-end: the INSTALLED persist-proposal.py, run standalone, must be
# self-sufficient. This is the only assertion that would have caught the
# missing lib/proposal_schema.py import — file-existence checks pass even
# when the import at the top of persist-proposal.py fails at runtime.
E2E_MARKER="installed-writer-e2e-$$"
E2E_PROPOSAL="$(printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "%s"}]}' "$E2E_MARKER")"
E2E_STATUS=0
printf '%s' "$E2E_PROPOSAL" | env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
    AGENT_LEARNING_HOME="$STORE" \
    ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
    python3 "${RESOLVED_SCRIPTS}/persist-proposal.py" >/tmp/e2e-writer-out.$$ 2>&1 || E2E_STATUS=$?
check "installed persist-proposal.py exits 0 standalone" "0" "$E2E_STATUS"
check "installed persist-proposal.py wrote the memory file" "yes" \
    "$([[ -f "${STORE}/memory/MEMORY.md" ]] && echo yes || echo no)"
check "installed persist-proposal.py wrote the expected content" "$E2E_MARKER" \
    "$(cat "${STORE}/memory/MEMORY.md" 2>/dev/null || echo MISSING)"
if [[ "$E2E_STATUS" -ne 0 ]]; then
    echo "--- installed persist-proposal.py output for debugging ---"
    cat /tmp/e2e-writer-out.$$
fi
rm -f /tmp/e2e-writer-out.$$

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

## ============================================================
## M14: a script listed in install.sh's own SCRIPTS array but missing from
## the source tree used to print "[WARN] Script not found" and CONTINUE,
## exiting 0 -- a genuinely broken install (the writer, or any other
## required script, silently absent) reported success. Must now be fatal.
## ============================================================
MISSING_SCRIPT_SRC="$(mktemp -d)"
cp -r "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/config" "${SCRIPT_DIR}/prompts" \
      "${SCRIPT_DIR}/schema" "${SCRIPT_DIR}/scripts" "${SCRIPT_DIR}/vendor" \
      "$MISSING_SCRIPT_SRC/" 2>/dev/null
rm -f "${MISSING_SCRIPT_SRC}/scripts/persist-proposal.py"

MISSING_TMP_HOME="$(mktemp -d)"
MISSING_STATUS=0
MISSING_OUT="$(env -i HOME="$MISSING_TMP_HOME" PATH="$MINIMAL_PATH" \
    AGENT_LEARNING_HOME="${MISSING_TMP_HOME}/store" \
    ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
    bash "${MISSING_SCRIPT_SRC}/install.sh" </dev/null 2>&1)" || MISSING_STATUS=$?

check "M14: install.sh with a missing SCRIPTS entry exits non-zero" "1" "$MISSING_STATUS"
case "$MISSING_OUT" in
    *"persist-proposal.py"*) echo "PASS: M14: install.sh names the missing script" ;;
    *) echo "FAIL: M14: install.sh's fatal error does not name the missing script"; FAILURES=$((FAILURES+1)) ;;
esac
rm -rf "$MISSING_SCRIPT_SRC" "$MISSING_TMP_HOME"


# ---------------------------------------------------------------------------
# Copilot hook upgrade path. install.sh used to print "Already exists ...
# (skipping)" for any pre-existing ~/.copilot/hooks/self-learning.json, so a
# user upgrading from the pre-vendor-neutral layout kept a hook pointing at
# ~/.claude/scripts/self-learning/..., re-ran the installer, was told it
# succeeded, and got no learning at all. Nothing covered this branch.
# ---------------------------------------------------------------------------
# NOTE ON PATHS (fix round: windows-latest). Every expectation below is
# expressed with $RESOLVED_SCRIPTS -- the scripts dir as paths.py reports it
# -- never "${STORE}/scripts". The two are the same directory but NOT the
# same string on Git Bash: RESOLVED_SCRIPTS crossed a python3.exe subprocess
# boundary and comes back in native (C:/...) form, while ${STORE} is the MSYS
# (/c/...) form that never left the shell. install.sh renders the hook from
# the SAME paths.py value, so the file on disk holds the native form. The
# first version of these tests compared against ${STORE}/scripts and failed
# on both Windows cells for that reason alone -- the installer was correct.
# See the identical warning at the sl_check_same_path call above.
#
# The stale/edited fixtures below are built by REWRITING the hook install.sh
# just wrote, rather than by re-rendering the template with a path this shell
# constructed, so nothing here has to know which form is in use.
COPILOT_HOOK="${TMP_HOME}/.copilot/hooks/self-learning.json"

# Rewrite whatever directory currently precedes our script name to $1.
# Same basic-sed normalization install.sh itself uses, for the same
# portability reasons (GNU/BSD/MSYS).
repoint_hook_to() {
    sed "s#[^\" ]*/copilot-session-review\.sh#$1/copilot-session-review.sh#g" \
        "$COPILOT_HOOK" > "${COPILOT_HOOK}.new"
    mv "${COPILOT_HOOK}.new" "$COPILOT_HOOK"
}
LEGACY_DIR="${TMP_HOME}/.claude/scripts/self-learning"

# U1: a STALE hook (ours, pointing at the pre-branch ~/.claude location) must
# be re-rendered. It used to be skipped with "Already exists ... (skipping)",
# which made upgrading a silent no-op: the installer reported success and the
# hook kept running a script that was no longer there.
repoint_hook_to "$LEGACY_DIR"
UPGRADE_OUT="$(run_install 2>&1)" || true
check "U1: a stale Copilot hook is re-rendered, not silently skipped" "yes" \
    "$(grep -qF "${RESOLVED_SCRIPTS}/copilot-session-review.sh" "$COPILOT_HOOK" && echo yes || echo no)"
check "U1: the stale path is gone from the hook" "yes" \
    "$(grep -qF "$LEGACY_DIR" "$COPILOT_HOOK" && echo no || echo yes)"
check "U1: the re-rendered hook points at a script that exists" "yes" \
    "$([[ -f "${RESOLVED_SCRIPTS}/copilot-session-review.sh" ]] && echo yes || echo no)"
case "$UPGRADE_OUT" in
    *"UPDATED (was stale)"*) echo "PASS: U1: the update is reported, not silent" ;;
    *) echo "FAIL: U1: install.sh did not report updating the stale hook"; FAILURES=$((FAILURES+1)) ;;
esac
# The old branch printed exactly "  Already exists: <path> (skipping)".
# Matched on the hook path so this cannot be satisfied by Step 4's unrelated
# "Config already exists ... skipping" line.
case "$UPGRADE_OUT" in
    *"Already exists: ${COPILOT_HOOK}"*) echo "FAIL: U1: install.sh still silently skips the existing hook"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: U1: the silent-skip branch is gone" ;;
esac

# U2: an already-correct hook is left byte-for-byte alone. Compared as a
# before/after snapshot of the file itself -- no reconstructed expectation,
# so this asserts the actual property (nothing changed) independent of path
# form or line endings.
HOOK_BEFORE="$(cat "$COPILOT_HOOK")"
UPTODATE_OUT="$(run_install 2>&1)" || true
case "$UPTODATE_OUT" in
    *"Up to date"*) echo "PASS: U2: an already-correct hook is reported up to date" ;;
    *) echo "FAIL: U2: a correct hook was not reported as up to date"; FAILURES=$((FAILURES+1)) ;;
esac
check "U2: an already-correct hook is unchanged" "$HOOK_BEFORE" "$(cat "$COPILOT_HOOK")"

# U3: ours but locally EDITED -- still upgraded (a broken path must not
# survive an upgrade) but the previous file is preserved and named.
repoint_hook_to "$LEGACY_DIR"
sed 's|"timeoutSec": 30|"timeoutSec": 99|' "$COPILOT_HOOK" > "${COPILOT_HOOK}.new"
mv "${COPILOT_HOOK}.new" "$COPILOT_HOOK"
EDITED_OUT="$(run_install 2>&1)" || true
check "U3: a locally-edited hook is still repointed at the real store" "yes" \
    "$(grep -qF "${RESOLVED_SCRIPTS}/copilot-session-review.sh" "$COPILOT_HOOK" && echo yes || echo no)"
check "U3: the user's previous file is preserved as a .bak" "yes" \
    "$(ls "${TMP_HOME}/.copilot/hooks/"*.bak-* >/dev/null 2>&1 && echo yes || echo no)"
check "U3: the .bak still holds the user's edit" "yes" \
    "$(grep -qF '"timeoutSec": 99' "${TMP_HOME}/.copilot/hooks/"*.bak-* && echo yes || echo no)"
case "$EDITED_OUT" in
    *"previous version saved to"*) echo "PASS: U3: the backup location is printed" ;;
    *) echo "FAIL: U3: install.sh did not say where the backup went"; FAILURES=$((FAILURES+1)) ;;
esac
rm -f "${TMP_HOME}/.copilot/hooks/"*.bak-*

# U4: a hook file that is NOT ours must never be overwritten, and the
# installer must say so loudly enough that "install succeeded" cannot be
# mistaken for "Copilot sessions are being reviewed".
FOREIGN_HOOK='{"version": 1, "hooks": {"sessionEnd": [{"type": "command", "bash": "bash /opt/somebody-else/thing.sh"}]}}'
printf '%s\n' "$FOREIGN_HOOK" > "$COPILOT_HOOK"
FOREIGN_OUT="$(run_install 2>&1)" || true
check "U4: a foreign hook file is not overwritten" "$FOREIGN_HOOK" "$(cat "$COPILOT_HOOK")"
case "$FOREIGN_OUT" in
    *"NOT INSTALLED"*) echo "PASS: U4: the refusal is reported at the point it happens" ;;
    *) echo "FAIL: U4: install.sh silently skipped a foreign hook file"; FAILURES=$((FAILURES+1)) ;;
esac
case "$FOREIGN_OUT" in
    *"ACTION REQUIRED"*) echo "PASS: U4: the refusal is repeated in the final summary" ;;
    *) echo "FAIL: U4: the final summary still claims Copilot hooks were installed"; FAILURES=$((FAILURES+1)) ;;
esac
rm -f "$COPILOT_HOOK"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- install.sh output (first run) for debugging ---"
    printf '%s\n' "$INSTALL_OUT"
    echo "--- install.sh output (M14 missing-script run) for debugging ---"
    printf '%s\n' "${MISSING_OUT:-}"
    exit 1
fi
echo "All install-paths tests passed."
