#!/usr/bin/env bash
# tests/test-copilot-hook-normalize.sh
#
# install.sh Step 4b classifies an existing Copilot hook file into three
# states, and the whole classification turns on ONE operation: normalizing the
# install path back to the template's `__SL_SCRIPTS_DIR__` placeholder. Get it
# wrong and "ours, just installed somewhere else" (re-render silently) is
# indistinguishable from "ours, the user edited it" (re-render, keep a .bak,
# tell them to re-apply their changes by hand).
#
# It was wrong. The normalizer was `sed 's#[^" ]*/copilot-session-review\.sh#..#g'`
# and that class excludes the space, so a store path containing one was only
# partly replaced:
#
#   in   "bash": "bash /home/u/My Store/scripts/copilot-session-review.sh"
#   out  "bash": "bash /home/u/My __SL_SCRIPTS_DIR__/copilot-session-review.sh"
#
# Measured consequence, end-to-end through install.sh: relocating a store whose
# path contains a space printed "UPDATED (had local modifications)" and left a
# .bak behind, where the byte-for-byte identical run with a space-free path
# printed "UPDATED (was stale)" and left none. Section 3 below is that exact
# comparison, so the assertion is on install.sh's real behaviour rather than on
# the normalizer's internals.
#
# Sections 1 and 2 pin the cases that make the obvious fixes wrong: the two
# DIFFERENT anchor shapes config/copilot-hooks.json actually contains (`bash
# <path>` and `bash -lc \"<path>\"`), both Windows path spellings paths.py can
# emit, and a genuine user customization that must NOT be normalized away.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

NORMALIZER="${SCRIPT_DIR}/scripts/lib/normalize-hook-path.py"
TEMPLATE="${SCRIPT_DIR}/config/copilot-hooks.json"
SCRIPT_NAME="copilot-session-review.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check "normalizer exists" "yes" "$([[ -f "$NORMALIZER" ]] && echo yes || echo no)"
if [[ ! -f "$NORMALIZER" ]]; then
    echo "RESULT: FAIL (${FAILURES} failure(s)) -- normalizer missing, nothing else can run"
    exit 1
fi

# norm_line <text> -- normalize a single line of hook JSON, print the result.
norm_line() {
    printf '%s\n' "$1" > "${TMP}/line.json"
    python3 "$NORMALIZER" "${TMP}/line.json" "$SCRIPT_NAME"
}

# --- 1. Both value shapes, both path spellings, with and without a space ---
#
# Each case is <label>|<input>|<expected>. A fix that handles the `bash` value
# but not the `powershell` one -- or vice versa, which is exactly what the two
# obvious sed widenings do -- fails here rather than in production.
while IFS='|' read -r label input expected; do
    [[ -z "$label" ]] && continue
    check "normalize: ${label}" "$expected" "$(norm_line "$input")"
done <<'CASES'
bash value, no space|  "bash": "bash /home/u/store/scripts/copilot-session-review.sh",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
bash value, space in path|  "bash": "bash /home/u/My Store/scripts/copilot-session-review.sh",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
powershell value, no space|  "powershell": "bash -lc \"/home/u/store/scripts/copilot-session-review.sh\"",|  "powershell": "bash -lc \"__SL_SCRIPTS_DIR__/copilot-session-review.sh\"",
powershell value, space in path|  "powershell": "bash -lc \"/home/u/My Store/scripts/copilot-session-review.sh\"",|  "powershell": "bash -lc \"__SL_SCRIPTS_DIR__/copilot-session-review.sh\"",
windows native drive form|  "bash": "bash C:/Users/u/store/scripts/copilot-session-review.sh",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
windows native drive form, space in path|  "bash": "bash C:/Users/u/My Store/scripts/copilot-session-review.sh",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
windows MSYS form|  "bash": "bash /c/Users/u/store/scripts/copilot-session-review.sh",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
windows native drive form, powershell value|  "powershell": "bash -lc \"C:/Users/u/My Store/scripts/copilot-session-review.sh\"",|  "powershell": "bash -lc \"__SL_SCRIPTS_DIR__/copilot-session-review.sh\"",
CASES

# The SHIPPING shape: the hook command shell-quotes its path, so the scan's
# left boundary is now an apostrophe rather than a space or a `\"`. The cases
# above are kept, unquoted, on purpose -- that is exactly what is on disk for
# anyone upgrading from a pre-quoting install, and install.sh has to keep
# classifying those as "ours, relocated" rather than spraying a .bak.
while IFS='|' read -r label input expected; do
    [[ -z "$label" ]] && continue
    check "normalize: ${label}" "$expected" "$(norm_line "$input")"
done <<'QUOTED_CASES'
quoted bash value, no space|  "bash": "bash '/home/u/store/scripts/copilot-session-review.sh'",|  "bash": "bash '__SL_SCRIPTS_DIR__/copilot-session-review.sh'",
quoted bash value, space in path|  "bash": "bash '/home/u/My Store/scripts/copilot-session-review.sh'",|  "bash": "bash '__SL_SCRIPTS_DIR__/copilot-session-review.sh'",
quoted powershell value, no space|  "powershell": "bash -lc \"'/home/u/store/scripts/copilot-session-review.sh'\"",|  "powershell": "bash -lc \"'__SL_SCRIPTS_DIR__/copilot-session-review.sh'\"",
quoted powershell value, space in path|  "powershell": "bash -lc \"'/home/u/My Store/scripts/copilot-session-review.sh'\"",|  "powershell": "bash -lc \"'__SL_SCRIPTS_DIR__/copilot-session-review.sh'\"",
quoted bash value, windows native drive form|  "bash": "bash 'C:/Users/u/My Store/scripts/copilot-session-review.sh'",|  "bash": "bash '__SL_SCRIPTS_DIR__/copilot-session-review.sh'",
QUOTED_CASES

# --- 1b. --print-path: the same scan, asked for the directory ---
#
# install.sh's "UPDATED (was stale)" branch prints where the hook used to
# point, and used to recover that with a sed expression of its own. That
# expression anchored on `.sh"` and silently degraded to `<unknown>` the
# moment the value gained quoting -- a success message that had stopped
# saying what changed. It is now the same scan as the rewrite above.
print_path() {
    printf '%s\n' "$1" > "${TMP}/pp.json"
    python3 "$NORMALIZER" --print-path "${TMP}/pp.json" "$SCRIPT_NAME"
}
check "print-path: quoted bash value with a space" "/home/u/My Store/scripts" \
    "$(print_path '  "bash": "bash '"'"'/home/u/My Store/scripts/copilot-session-review.sh'"'"'",')"
check "print-path: unquoted bash value (pre-quoting install)" "/home/u/store/scripts" \
    "$(print_path '  "bash": "bash /home/u/store/scripts/copilot-session-review.sh",')"
check "print-path: windows native drive form" "C:/Users/u/My Store/scripts" \
    "$(print_path '  "bash": "bash '"'"'C:/Users/u/My Store/scripts/copilot-session-review.sh'"'"'",')"
# Already normalized: no install path to report. Must print NOTHING and exit
# 0, so install.sh's `${OLD_HOOK_PATH:-<unknown>}` is what fills the gap
# rather than a stray placeholder appearing in the message.
check "print-path: prints nothing when there is no install path" "" \
    "$(print_path '  "bash": "bash '"'"'__SL_SCRIPTS_DIR__/copilot-session-review.sh'"'"'",')"

# --- 2. What must NOT be normalized ---
#
# Normalizing too much is the mirror-image defect: it makes a user's edit look
# like a mere relocation, so install.sh re-renders over it WITHOUT a .bak and
# the edit is gone. The interpreter prefix is the case that catches a
# leftmost-match implementation.
check "user's explicit interpreter survives" \
    '  "bash": "bash /usr/bin/env bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",' \
    "$(norm_line '  "bash": "bash /usr/bin/env bash /home/u/store/scripts/copilot-session-review.sh",')"
check "an unrelated script is untouched" \
    '  "bash": "bash /home/u/other/some-other-hook.sh",' \
    "$(norm_line '  "bash": "bash /home/u/other/some-other-hook.sh",')"
# A RELATIVE script path has no install path in front of it to strip, so the
# scan must give up -- not keep walking left, out of the JSON string literal,
# until it finds something slash-shaped in a neighbouring value. That would
# splice two values into one placeholder and destroy the file. The two cases
# differ in what sits between: a quote (the string boundary) and a backslash
# (a JSON escape we have not decoded, so we cannot be inside a path).
check "scan does not cross a quote into another value" \
    '  "note": "/tmp/x", "bash": "bash scripts/copilot-session-review.sh",' \
    "$(norm_line '  "note": "/tmp/x", "bash": "bash scripts/copilot-session-review.sh",')"
check "scan does not cross a JSON escape" \
    '  "bash": "bash /opt\\a scripts/copilot-session-review.sh",' \
    "$(norm_line '  "bash": "bash /opt\\a scripts/copilot-session-review.sh",')"
check "already-normalized text is unchanged (idempotent)" \
    '  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",' \
    "$(norm_line '  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",')"

# The round trip is the property install.sh actually depends on: render the
# template into a path, normalize it back, get the template's bytes returned.
# Asserted for the whole file, not a line, so a normalizer that mangles
# trailing bytes (which would make every install look stale) is caught.
for store in '/home/u/store/scripts' '/home/u/My Store/scripts' 'C:/Users/u/My Store/scripts' '/c/Users/u/store/scripts'; do
    printf '%s' "$store" | python3 "${SCRIPT_DIR}/scripts/lib/render-template.py" "$TEMPLATE" > "${TMP}/rendered.json"
    check "round trip restores the template: ${store}" \
        "$(cat "$TEMPLATE")" \
        "$(python3 "$NORMALIZER" "${TMP}/rendered.json" "$SCRIPT_NAME")"
done

# --- 3. The real consequence, through install.sh ---
#
# Two identical relocation sequences, differing only by a space in the store
# path. Both must reach the "was stale" branch and leave no backup file. Before
# the fix the space run reported "had local modifications" and left a .bak.
# Sandboxed with `env -i` and a throwaway HOME: install.sh writes to
# $HOME/.copilot and the resolved store, and must never see the real ones.
relocation_case() {
    local suffix="$1" a="$2" b="$3" home
    home="${TMP}/home-${suffix}"
    mkdir -p "${home}/.copilot"
    env -i HOME="$home" AGENT_LEARNING_HOME="${home}/${a}" PATH="$PATH" \
        bash "${SCRIPT_DIR}/install.sh" >"${TMP}/install1-${suffix}.log" 2>&1
    env -i HOME="$home" AGENT_LEARNING_HOME="${home}/${b}" PATH="$PATH" \
        bash "${SCRIPT_DIR}/install.sh" >"${TMP}/install2-${suffix}.log" 2>&1
}

for suffix in nospace space; do
    if [[ "$suffix" == "nospace" ]]; then
        relocation_case "$suffix" "StoreA" "StoreB"
    else
        relocation_case "$suffix" "My Store A" "My Store B"
    fi
    log="${TMP}/install2-${suffix}.log"
    check "relocation (${suffix}): reported as stale, not as user-modified" "1" \
        "$(grep -c 'UPDATED (was stale)' "$log" || true)"
    check "relocation (${suffix}): no 'had local modifications'" "0" \
        "$(grep -c 'had local modifications' "$log" || true)"
    check "relocation (${suffix}): no backup file left behind" "0" \
        "$(find "${TMP}/home-${suffix}/.copilot/hooks" -name '*.bak-*' | wc -l | tr -d ' ')"
    # The stale branch also PRINTS the old location, via a second path-matching
    # expression. A space there would report `<unknown>` while still claiming
    # success -- the same class of silent wrongness one line further on.
    check "relocation (${suffix}): old location reported, not <unknown>" "0" \
        "$(grep -c '<unknown>' "$log" || true)"
done

# The hook actually installed at the end must still name a real, existing
# script -- the point of all of the above.
hook="${TMP}/home-space/.copilot/hooks/self-learning.json"
check "final hook parses as JSON" "yes" \
    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("yes")' "$hook" 2>/dev/null || echo no)"
check "final hook names an existing script" "yes" \
    "$(python3 - "$hook" <<'PY' 2>/dev/null || echo no
import json, os, shlex, sys
# shlex, not cmd[len("bash "):]: the hook command shell-quotes its path (see
# tests/test-hook-command-quoting.sh), so the fixed-width slice used to leave
# an apostrophe on both ends and report a correct hook as missing.
cmd = json.load(open(sys.argv[1]))["hooks"]["sessionEnd"][0]["bash"]
print("yes" if os.path.isfile(shlex.split(cmd, posix=True)[-1]) else "no")
PY
)"

if [[ $FAILURES -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (${FAILURES} failure(s))"
    exit 1
fi
