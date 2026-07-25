#!/usr/bin/env bash
# tests/test-ps1-wrappers.sh
#
# install.ps1/uninstall.ps1 cannot be executed here: this repo's CI has no
# PowerShell job and the development host has no pwsh (probed below and
# reported, never silently skipped). What CAN be pinned without PowerShell:
#
#  1. The structural contract — both wrappers must resolve bash through the
#     shared scripts/lib/find-bash.ps1 probe rather than invoking the first
#     `bash` on PATH directly. That direct invocation is the defect being
#     fixed: on Windows the first bash may be WSL's launcher, which cannot
#     see the repo's Windows path and whose $HOME is a different user's, so
#     delegating to it either fails obscurely or installs into the wrong
#     filesystem.
#  2. The probe IDIOM itself, which is pure bash and therefore fully
#     testable here: `bash -c 'test -f "$1"' -- <path>` must exit 0 for a
#     path this bash can see and non-zero for one it cannot. That is exactly
#     the question find-bash.ps1 asks the bash it found, so if the idiom is
#     wrong the whole check is wrong, PowerShell or not.
#  3. That the decision is functional, not a filename/System32 match — the
#     same discipline as the dir_fd and symlink probes elsewhere in this
#     suite.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

HELPER="${SCRIPT_DIR}/scripts/lib/find-bash.ps1"
check "shared bash-resolver helper exists" "yes" "$([[ -f "$HELPER" ]] && echo yes || echo no)"

for wrapper in install uninstall; do
    f="${SCRIPT_DIR}/${wrapper}.ps1"
    check "${wrapper}.ps1 exists" "yes" "$([[ -f "$f" ]] && echo yes || echo no)"
    [[ -f "$f" ]] || continue
    check "${wrapper}.ps1 dot-sources find-bash.ps1" "yes" \
        "$(grep -q 'find-bash\.ps1' "$f" && echo yes || echo no)"
    check "${wrapper}.ps1 resolves bash through the probe" "yes" \
        "$(grep -q 'Resolve-DelegableBash' "$f" && echo yes || echo no)"
    # The pre-fix pattern: taking Get-Command bash's .Source and invoking it
    # with no check that it can see the repo at all.
    check "${wrapper}.ps1 does not invoke Get-Command bash directly" "yes" \
        "$(grep -q 'Get-Command bash' "$f" && echo no || echo yes)"
done

if [[ -f "$HELPER" ]]; then
    check "helper probes with 'test -f' rather than matching a filename" "yes" \
        "$(grep -q "test -f" "$HELPER" && echo yes || echo no)"
    # A System32/name match would reject non-System32 WSL shims not at all
    # and could wrongly reject an unusual but working bash. The helper may
    # *mention* System32 in its explanatory message; it must not branch on it.
    check "helper does not branch on a System32 path match" "yes" \
        "$(grep -qE '^[^#]*(-like|-match|StartsWith).*[Ss]ystem32' "$HELPER" && echo no || echo yes)"
fi

# --- The probe idiom, executed for real (this part needs no PowerShell) ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\n' >"${TMP}/install.sh"

set +e
bash -c 'test -f "$1"' -- "${TMP}/install.sh" >/dev/null 2>&1
VISIBLE_RC=$?
# A Windows-style path is what a WSL bash would be handed by the wrapper and
# would be unable to open -- stand-in for that case on any platform.
bash -c 'test -f "$1"' -- 'C:/definitely/not/here/install.sh' >/dev/null 2>&1
INVISIBLE_RC=$?
set -e

check "probe idiom: exits 0 for a path this bash can see" "0" "$VISIBLE_RC"
check "probe idiom: exits non-zero for a path it cannot" "yes" \
    "$([[ "$INVISIBLE_RC" -ne 0 ]] && echo yes || echo no)"

if command -v pwsh >/dev/null 2>&1; then
    echo "[capability probe] pwsh: AVAILABLE -- syntax-checking the wrappers"
    for f in "${SCRIPT_DIR}/install.ps1" "${SCRIPT_DIR}/uninstall.ps1" "$HELPER"; do
        if pwsh -NoProfile -Command "
\$ErrorActionPreference='Stop'
\$null = [System.Management.Automation.Language.Parser]::ParseFile('$f', [ref]\$null, [ref]\$errs)
if (\$errs) { exit 1 }" >/dev/null 2>&1; then
            echo "PASS: $(basename "$f") parses"
        else
            echo "FAIL: $(basename "$f") has a PowerShell parse error"
            FAILURES=$((FAILURES+1))
        fi
    done
else
    echo "[capability probe] pwsh: NOT AVAILABLE -- PowerShell parse/behaviour of the"
    echo "  wrappers is UNVERIFIED here (structural checks above still ran). This is"
    echo "  reported, not skipped silently: nothing in this repo has ever executed"
    echo "  install.ps1 on Windows."
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All ps1-wrapper tests passed."
