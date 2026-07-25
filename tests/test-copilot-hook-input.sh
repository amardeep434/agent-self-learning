#!/usr/bin/env bash
# tests/test-copilot-hook-input.sh
#
# scripts/lib/copilot-hook-input.sh (Copilot CLI sessionEnd payload parsing)
# and scripts/lib/stdin-safe.sh (the TTY-hang guard it and hook-input.sh
# both use).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
        FAILURES=$((FAILURES + 1))
    fi
}

# Case 1: full payload
OUT=$(echo '{"sessionId":"d60c51bf-2130-449c-89c5-c65ea49d8cb8","timestamp":1784982920820,"cwd":"/tmp/proj","reason":"complete"}' \
    | bash -c "source '${SCRIPT_DIR}/scripts/lib/copilot-hook-input.sh'; echo \"\$COPILOT_HOOK_SESSION_ID|\$COPILOT_HOOK_CWD|\$COPILOT_HOOK_REASON\"")
check "full payload" "d60c51bf-2130-449c-89c5-c65ea49d8cb8|/tmp/proj|complete" "$OUT"

# Case 2: empty stdin (piped, not a terminal)
OUT=$(printf '' | bash -c "source '${SCRIPT_DIR}/scripts/lib/copilot-hook-input.sh'; echo \"\$COPILOT_HOOK_SESSION_ID|\$COPILOT_HOOK_REASON\"")
check "empty stdin" "|" "$OUT"

# Case 3: malformed JSON
OUT=$(echo 'not json' | bash -c "source '${SCRIPT_DIR}/scripts/lib/copilot-hook-input.sh'; echo \"\$COPILOT_HOOK_SESSION_ID\"")
check "malformed JSON" "" "$OUT"

# Case 4: sessionId missing from an otherwise-valid payload
OUT=$(echo '{"reason":"complete"}' | bash -c "source '${SCRIPT_DIR}/scripts/lib/copilot-hook-input.sh'; echo \"\$COPILOT_HOOK_SESSION_ID|\$COPILOT_HOOK_REASON\"")
check "sessionId missing" "|complete" "$OUT"

# Case 5: TTY must never hang -- the real regression this guards. A genuine
# pseudo-tty is allocated (stdlib `pty`, no `script`/`expect` dependency) and
# attached as bash's stdin with NOTHING ever written to it; if
# sl_read_stdin_safe's `[[ -t 0 ]]` guard were missing, `cat` would block on
# it forever (would time out below) waiting for a Ctrl-D that never comes --
# exactly the "human runs a hook script by hand" scenario doctor.sh warns
# about. A 5s bound is generous; the guarded path returns in milliseconds.
PTY_TEST_OUT=$(python3 - "${SCRIPT_DIR}/scripts/lib/stdin-safe.sh" <<'PYEOF'
import os, pty, subprocess, sys, select

lib_path = sys.argv[1]
master, slave = pty.openpty()
proc = subprocess.Popen(
    ["bash", "-c", f"source '{lib_path}'; sl_read_stdin_safe; echo; echo DONE"],
    stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
)
os.close(slave)
ready, _, _ = select.select([proc.stdout], [], [], 5)
if not ready:
    print("TIMEOUT")
    proc.kill()
    sys.exit(0)
out = proc.stdout.read()
proc.wait(timeout=2)
print("DONE" if "DONE" in out else "NO_DONE_MARKER")
PYEOF
)
check "tty stdin does not hang sl_read_stdin_safe" "DONE" "$PTY_TEST_OUT"

# Case 6: piped stdin (the real hook path) is read fully, never short-circuited.
OUT=$(printf 'hello-world' | bash -c "source '${SCRIPT_DIR}/scripts/lib/stdin-safe.sh'; sl_read_stdin_safe")
check "piped stdin is read" "hello-world" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "All copilot-hook-input tests passed."
