#!/usr/bin/env bash
# tests/test-line-endings.sh
#
# C1 (partial): the reported "exit 127" on windows-latest for test-config.sh
# is most plausibly explained by CRLF line endings introduced by Windows'
# default core.autocrlf=true checkout behavior for any file Git guesses is
# text -- a trailing \r embedded in every shell line is a well-known source
# of exactly this failure mode (see .gitattributes for the full reasoning).
# This cannot be proven without Windows CI, so this test instead pins the
# defense: .gitattributes must force LF for every *.sh and *.py file this
# project ships, and no such file may already contain a literal \r in this
# checkout (which would mean .gitattributes alone is not enough -- e.g. a
# file was committed with CRLF directly).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

check ".gitattributes exists" "yes" "$([[ -f "${SCRIPT_DIR}/.gitattributes" ]] && echo yes || echo no)"

if [[ -f "${SCRIPT_DIR}/.gitattributes" ]]; then
    check ".gitattributes forces LF for *.sh" "yes" \
        "$(grep -qE '^\*\.sh[[:space:]]+text[[:space:]]+eol=lf' "${SCRIPT_DIR}/.gitattributes" && echo yes || echo no)"
    check ".gitattributes forces LF for *.py" "yes" \
        "$(grep -qE '^\*\.py[[:space:]]+text[[:space:]]+eol=lf' "${SCRIPT_DIR}/.gitattributes" && echo yes || echo no)"
fi

CRLF_FOUND=""
while IFS= read -r -d '' f; do
    if grep -qU $'\r' "$f" 2>/dev/null; then
        CRLF_FOUND="${CRLF_FOUND}${f}\n"
    fi
done < <(find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/tests" -type f \( -name '*.sh' -o -name '*.py' \) -print0)

if [[ -z "$CRLF_FOUND" ]]; then
    echo "PASS: no tracked .sh/.py file under scripts/ or tests/ contains a literal CR"
else
    echo "FAIL: CRLF line endings found in:"
    printf '%b' "$CRLF_FOUND"
    FAILURES=$((FAILURES+1))
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All line-ending tests passed."
