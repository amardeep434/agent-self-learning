#!/usr/bin/env bash
# tests/test-ps1-wrappers.sh
#
# install.ps1/uninstall.ps1 cannot be executed on a host with no pwsh (probed
# below and reported, never silently skipped). That is a property of the
# DEVELOPMENT machine only. CI runs the PowerShell half on ubuntu-latest AND
# on both windows-latest cells -- GitHub documents pwsh as the default shell
# on Windows runners, and run 30177841369 printed "[capability probe] pwsh:
# AVAILABLE (7.6.3)" on windows-latest before passing. A dedicated
# `shell: pwsh` job was considered and NOT added: it would be a seventh CI
# cell duplicating coverage that already runs. See tests/lib/
# ps-wrapper-tests.ps1's correction-of-record header.
#
# What CAN be pinned without PowerShell:
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

# --- PowerShell, wherever it exists ---------------------------------------
#
# fix-p9. This block previously assembled an inline `pwsh -NoProfile
# -Command` string in bash, and it was WRONG: it referenced a $errs variable
# it never initialised, under $ErrorActionPreference='Stop', which is a
# terminating error for every input file alike. The first CI run that had
# pwsh available duly reported all three wrappers as having parse errors --
# a false positive from the check, not a fault in the files. Two lessons,
# both applied here:
#
#   * Invoke via `-File`, never `-Command`. That removes the entire
#     bash-quoting/PowerShell-parsing interaction, which is what made the
#     broken check hard to see in the first place.
#   * PRINT the diagnostics. "has a parse error" with no line, column or
#     message is indistinguishable from a broken checker -- exactly the
#     ambiguity that cost a CI round trip.
#
# And a correction of record: this suite used to state that PowerShell was
# unverifiable because there is no PowerShell CI job. That was wrong.
# GitHub's ubuntu runners ship pwsh, so both the parse check AND the
# behavioural test below run on every push -- they just never ran on the
# dev box, which has no pwsh. "Absent locally" is not "absent in CI".
if command -v pwsh >/dev/null 2>&1; then
    echo "[capability probe] pwsh: AVAILABLE ($(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo 'version unknown'))"

    # `VAR="$(cmd)"` under `set -e` ABORTS the script when cmd fails, so a
    # genuine parse error would kill this suite before it could print the
    # diagnostics it just collected -- silently turning a reportable failure
    # into a truncated log. `|| RC=$?` keeps the failure reportable. (Found
    # by mutation-testing this very block: the injected syntax error
    # produced no output at all until this was fixed.)
    PARSE_RC=0
    PARSE_OUT="$(pwsh -NoProfile -File "${SCRIPT_DIR}/tests/lib/ps-parse-check.ps1" \
        "${SCRIPT_DIR}/install.ps1" "${SCRIPT_DIR}/uninstall.ps1" "$HELPER" \
        "${SCRIPT_DIR}/tests/lib/ps-parse-check.ps1" "${SCRIPT_DIR}/tests/lib/ps-wrapper-tests.ps1" 2>&1)" \
        || PARSE_RC=$?
    printf '%s\n' "$PARSE_OUT" | sed 's/^/  /'
    check "every shipped .ps1 file parses" "0" "$PARSE_RC"

    # Behaviour, not just syntax: a resolver that parses but picks the wrong
    # bash would sail through a parse check. Both branches of
    # Resolve-DelegableBash are platform-independent, so running them here
    # exercises the real code rather than a simulation of it.
    BEHAVIOUR_RC=0
    BEHAVIOUR_OUT="$(pwsh -NoProfile -File "${SCRIPT_DIR}/tests/lib/ps-wrapper-tests.ps1" \
        "${SCRIPT_DIR}" 2>&1)" || BEHAVIOUR_RC=$?
    printf '%s\n' "$BEHAVIOUR_OUT" | sed 's/^/  /'
    check "find-bash.ps1 resolver behaves correctly (accept + refuse)" "0" "$BEHAVIOUR_RC"
else
    echo "[capability probe] pwsh: NOT AVAILABLE -- the PowerShell parse check and the"
    echo "  find-bash.ps1 behaviour test did NOT run here (the structural checks above"
    echo "  still did). Reported, not skipped silently. Note this is a property of THIS"
    echo "  machine, not of CI: GitHub's ubuntu runners ship pwsh and do run both."
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All ps1-wrapper tests passed."
