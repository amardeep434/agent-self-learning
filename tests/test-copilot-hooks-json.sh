#!/usr/bin/env bash
# tests/test-copilot-hooks-json.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

HOOK="${SCRIPT_DIR}/config/copilot-hooks.json"
check "bash command present" "yes" "$(jq -e '.hooks.sessionEnd[0].bash | length > 0' "$HOOK" >/dev/null && echo yes)"
check "powershell command present" "yes" "$(jq -e '.hooks.sessionEnd[0].powershell | length > 0' "$HOOK" >/dev/null && echo yes || echo no)"
check "powershell delegates to bash" "yes" "$(jq -r '.hooks.sessionEnd[0].powershell' "$HOOK" | grep -q '^bash ' && echo yes || echo no)"
check "ps1 installer exists" "yes" "$([[ -f "${SCRIPT_DIR}/install.ps1" ]] && echo yes || echo no)"
check "ps1 uninstaller exists" "yes" "$([[ -f "${SCRIPT_DIR}/uninstall.ps1" ]] && echo yes || echo no)"
check "bash carries scripts-dir placeholder" "yes" "$(jq -r '.hooks.sessionEnd[0].bash' "$HOOK" | grep -q '__SL_SCRIPTS_DIR__' && echo yes || echo no)"
check "powershell carries scripts-dir placeholder" "yes" "$(jq -r '.hooks.sessionEnd[0].powershell' "$HOOK" | grep -q '__SL_SCRIPTS_DIR__' && echo yes || echo no)"
check "template contains no .claude" "0" "$(grep -c '\.claude' "$HOOK" || true)"

# --- Route B: the sessionStart registration must exist and be well-formed.
#     Added 2026-07-30 after a mutation audit deleted the whole
#     hooks.sessionStart block from the template and EIGHT suites still passed --
#     Route B silently dead for one of three peer harnesses, guarded by nothing.
#     The other two templates were guarded; only Copilot's was not.
check "sessionStart is registered (the learned-context read-back)" "yes" \
    "$(jq -e '.hooks.sessionStart[0].bash | test("session-start-context")' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "sessionStart bash carries the scripts-dir placeholder" "yes" \
    "$(jq -r '.hooks.sessionStart[0].bash' "$HOOK" | grep -q '__SL_SCRIPTS_DIR__' && echo yes || echo no)"
check "sessionStart has a powershell sibling (Windows)" "yes" \
    "$(jq -e '.hooks.sessionStart[0].powershell | test("session-start-context")' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "sessionStart powershell carries the placeholder" "yes" \
    "$(jq -r '.hooks.sessionStart[0].powershell' "$HOOK" | grep -q '__SL_SCRIPTS_DIR__' && echo yes || echo no)"
check "sessionStart type is command" "command" "$(jq -r '.hooks.sessionStart[0].type' "$HOOK")"
check "sessionStart timeoutSec is a plausible number of SECONDS" "yes" \
    "$(t=$(jq -r '.hooks.sessionStart[0].timeoutSec' "$HOOK"); [[ "$t" =~ ^[0-9]+$ && "$t" -ge 1 && "$t" -le 600 ]] && echo yes || echo no)"


if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All copilot-hooks-json tests passed."
