#!/usr/bin/env bash
# tests/test-claude-hooks-json.sh
#
# Static guard on config/settings-hooks.json, the Claude Code hook-registration
# template. Its Copilot counterpart has had tests/test-copilot-hooks-json.sh
# since Task 6; this file had none, which is how defect A1 survived: the
# template kept naming ~/.claude/scripts/self-learning/, a directory install.sh
# stopped writing to at Task 7b, and no test looked at the script paths.
#
# The three things asserted here are the three halves A1 was broken in (the
# schema, the timeout unit, and the script path), plus the placeholder that
# keeps this file the single definition install.sh renders rather than a second
# copy to drift from.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

HOOK="${SCRIPT_DIR}/config/settings-hooks.json"

check "template exists" "yes" "$([[ -f "$HOOK" ]] && echo yes || echo no)"
check "template parses as JSON" "yes" "$(jq -e . "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"

# --- The nested schema. Claude Code requires three levels: event -> matcher
# group -> hooks[]. The flat {matcher, command, timeout} shape parses as JSON
# and is silently ignored, which is the worst possible failure here.
check "PostToolUse uses the nested hooks[] schema" "yes" \
    "$(jq -e '.hooks.PostToolUse[0].hooks[0].type == "command"' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "Stop uses the nested hooks[] schema" "yes" \
    "$(jq -e '.hooks.Stop[0].hooks[0].type == "command"' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "no command sits directly on a matcher group (the flat schema)" "0" \
    "$(jq '[.hooks[][] | select(has("command"))] | length' "$HOOK")"

# --- Every hook entry must be well-formed, whichever event it hangs off.
ENTRY_COUNT="$(jq '[.hooks[][].hooks[]] | length' "$HOOK")"
check "three hook entries (turn-counter, session-review, index-session)" "3" "$ENTRY_COUNT"
check "every entry has type=command" "$ENTRY_COUNT" \
    "$(jq '[.hooks[][].hooks[] | select(.type == "command")] | length' "$HOOK")"

# --- The timeout unit. Claude Code reads `timeout` in SECONDS (command default
# 600). install.sh used to print 3000/10000/15000 here, which would have given
# turn-counter.sh a 50-minute timeout on every PostToolUse.
check "every timeout is a plausible number of SECONDS (1..600)" "$ENTRY_COUNT" \
    "$(jq '[.hooks[][].hooks[] | select(.timeout >= 1 and .timeout <= 600)] | length' "$HOOK")"

# --- The script path. This is the ruling reversed by A1: a ~/.claude *config
# location* is fine (settings.json is Claude Code's own file), but the *script
# path it invokes* must be the vendor-neutral store, resolved at install time.
check "no hardcoded ~/.claude script path" "0" \
    "$(jq -r '.hooks[][].hooks[].command' "$HOOK" | grep -c '\.claude' || true)"
check "every command carries the scripts-dir placeholder" "$ENTRY_COUNT" \
    "$(jq -r '.hooks[][].hooks[].command' "$HOOK" | grep -c '__SL_SCRIPTS_DIR__' || true)"

# --- The three scripts named must be scripts that exist in this repo, so a
# typo or a rename cannot leave the template naming a file nobody ships.
while IFS= read -r cmd; do
    # Strip a trailing CR. .gitattributes guarantees the FILE is LF, but this
    # value came out of jq's stdout, and Git Bash's jq is a native Windows
    # build whose text-mode stdout emits CRLF -- so the CR is added at runtime,
    # after checkout. Without this, script_path is "turn-counter.sh\r", the -f
    # probe misses a file that plainly exists, and the failure prints as a
    # mangled two-line message. Same strip, same reason, as scripts/lib/config.sh.
    cmd="${cmd%$'\r'}"
    script_path="${cmd#bash __SL_SCRIPTS_DIR__/}"
    if [[ -f "${SCRIPT_DIR}/scripts/${script_path}" ]]; then
        echo "PASS: template names a real script: ${script_path}"
    else
        # Localize the failure instead of leaving a bare "expected yes, got no".
        # This probe failed on windows-latest while every count-based check in
        # this same suite passed, which rules out the obvious explanations
        # (jq missing, template unreadable, CRLF in jq's stdout -- a CRLF
        # stdout would have broken the count checks too). Dump the bytes so
        # the next Windows run says what the value actually is.
        echo "FAIL: template names a real script: ${script_path}"
        FAILURES=$((FAILURES+1))
        echo "  [diag] probed: ${SCRIPT_DIR}/scripts/${script_path}" >&2
        printf '  [diag] script_path bytes: ' >&2
        printf '%s' "$script_path" | od -c | head -2 >&2
        printf '  [diag] raw jq line bytes: ' >&2
        printf '%s' "$cmd" | od -c | head -2 >&2
        echo "  [diag] scripts dir listing:" >&2
        ls -1 "${SCRIPT_DIR}/scripts" 2>&1 | head -5 >&2
    fi
done < <(jq -r '.hooks[][].hooks[].command' "$HOOK")

# --- Regression from an earlier round: a hook pointing at a script that was
# planned but never written.
check "no reference to nonexistent rolling-transcript.sh" "0" \
    "$(grep -c 'rolling-transcript' "$HOOK" || true)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All claude-hooks-json tests passed."
