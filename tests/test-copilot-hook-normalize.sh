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
# shellcheck source=tests/lib/hook-command.sh
source "${SCRIPT_DIR}/tests/lib/hook-command.sh"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

NORMALIZER="${SCRIPT_DIR}/scripts/lib/normalize-hook-path.py"
TEMPLATE="${SCRIPT_DIR}/config/copilot-hooks.json"
SCRIPT_NAME="copilot-session-review.sh"
# Every script the real Copilot template registers. The single-line fixtures
# below each contain one script, so they keep passing $SCRIPT_NAME -- but the
# WHOLE-TEMPLATE cases must pass all of them, because the template gained a
# sessionStart hook on 2026-07-30 and normalizing only one name leaves the other
# path in place, which makes install.sh's textual freshness check see a
# correctly-installed hook as permanently stale.
ALL_SCRIPT_NAMES=(copilot-session-review.sh session-start-context.sh)

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

# --- 1c. --canonical: the same normalize, plus OUR quoting removed ---
#
# Normalizing alone compares an installed file against ONE template generation.
# 58098f7 changed the template's quoting, so on the next upgrade a file we had
# rendered ourselves normalized to the PREVIOUS template and install.sh
# reported "UPDATED (had local modifications)" with a .bak -- measured on a
# real upgrade. Canonical form is the comparison key that makes the two
# generations equal: both must reduce to the SAME unquoted text, and anything
# beyond our own quoting must survive.
canon_line() {
    printf '%s\n' "$1" > "${TMP}/canon.json"
    python3 "$NORMALIZER" --canonical "${TMP}/canon.json" "$SCRIPT_NAME"
}
while IFS='|' read -r label input expected; do
    [[ -z "$label" ]] && continue
    check "canonical: ${label}" "$expected" "$(canon_line "$input")"
done <<'CANON_CASES'
quoted bash value (current template)|  "bash": "bash '/home/u/store/scripts/copilot-session-review.sh'",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
unquoted bash value (pre-58098f7 install)|  "bash": "bash /home/u/store/scripts/copilot-session-review.sh",|  "bash": "bash __SL_SCRIPTS_DIR__/copilot-session-review.sh",
quoted powershell value (current template)|  "powershell": "bash -lc \"'/home/u/store/scripts/copilot-session-review.sh'\"",|  "powershell": "bash -lc __SL_SCRIPTS_DIR__/copilot-session-review.sh",
user quotes the whole command, not just the path|  "bash": "bash '/home/u/store/scripts/copilot-session-review.sh --flag'",|  "bash": "bash '__SL_SCRIPTS_DIR__/copilot-session-review.sh --flag'",
CANON_CASES

# That last case is the one that pins BALANCE. The quote before the token is
# ours; the one after it is not adjacent, it is at the end of the user's
# argument list. Stripping the opening quote without checking for a closing one
# eats the character on the right instead -- here the space in front of
# `--flag`, joining two words of the user's command into one. Symmetric input
# hides it (both sides lose a character in the same place), which is why the
# assertion is on this asymmetric line rather than on the template.

# The powershell expectation above is deliberately NOT hand-written a second
# time: the two generations of that value nest their quoting differently
# (`\"<path>\"` became `\"'<path>'\"`), so the only assertion that means
# anything is that they land on the SAME key. Asserting a literal would just
# re-encode whichever peeling order the implementation happens to use.
check "canonical: both powershell generations agree" "yes" \
    "$([[ "$(canon_line '  "powershell": "bash -lc \"'"'"'/home/u/store/scripts/copilot-session-review.sh'"'"'\"",')" \
        == "$(canon_line '  "powershell": "bash -lc \"/home/u/store/scripts/copilot-session-review.sh\"",')" ]] \
        && echo yes || echo no)"
# ...and the same for the whole shipping template against its pre-quoting form,
# which is what install.sh actually compares. Rendered, so the round trip is
# included rather than assumed.
printf '%s' '/home/u/store/scripts' | python3 "${SCRIPT_DIR}/scripts/lib/render-template.py" "$TEMPLATE" > "${TMP}/current.json"
tr -d "'" < "${TMP}/current.json" > "${TMP}/pre-quoting.json"
check "canonical: rendered template equals its pre-quoting form" \
    "$(python3 "$NORMALIZER" --canonical "$TEMPLATE" "${ALL_SCRIPT_NAMES[@]}")" \
    "$(python3 "$NORMALIZER" --canonical "${TMP}/pre-quoting.json" "${ALL_SCRIPT_NAMES[@]}")"
# The mirror image, and the one that must NOT collapse: a real edit next to the
# quoting still has to differ, or install.sh re-renders over it without a .bak.
sed "s#bash '#bash /usr/bin/env bash '#" "${TMP}/current.json" > "${TMP}/edited.json"
check "canonical: a user's wrapper still differs from the template" "differs" \
    "$([[ "$(python3 "$NORMALIZER" --canonical "${TMP}/edited.json" "${ALL_SCRIPT_NAMES[@]}")" \
        == "$(python3 "$NORMALIZER" --canonical "$TEMPLATE" "${ALL_SCRIPT_NAMES[@]}")" ]] \
        && echo same || echo differs)"

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
        "$(python3 "$NORMALIZER" "${TMP}/rendered.json" "${ALL_SCRIPT_NAMES[@]}")"
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
    check "relocation (${suffix}): the old location is actually printed" "1" \
        "$(grep -c 'previously ' "$log" || true)"
done

# --- 3b. Upgrading ACROSS a template shape change, through install.sh ---
#
# The relocation cases above move the store while the template holds still.
# This is the other axis, and the one that shipped broken: the store stays put
# and OUR template changes shape under it. Measured on the real upgrade past
# 58098f7 (single-quoting the rendered path), against a file the user had never
# touched:
#
#   UPDATED (had local modifications): ~/.copilot/hooks/self-learning.json
#     previous version saved to: ...bak-20260729T052022Z
#     re-apply any customizations from that file by hand.
#
# A false accusation, a spurious .bak, and instructions to re-apply edits that
# do not exist. The pre-quoting file is reconstructed by deleting the
# apostrophes from a real render rather than by pinning a literal, so this stays
# honest if the template moves again -- and the edited counter-case below is run
# through the same machinery, because a fix that stops the false positive by
# forgiving MORE than our own quoting is a silent data-loss bug.
upgrade_home="${TMP}/home-upgrade"
mkdir -p "${upgrade_home}/.copilot"
sl_install_into() {
    env -i HOME="$upgrade_home" AGENT_LEARNING_HOME="${upgrade_home}/store" PATH="$PATH" \
        bash "${SCRIPT_DIR}/install.sh" >"$1" 2>&1
}
upgrade_hook="${upgrade_home}/.copilot/hooks/self-learning.json"
sl_install_into "${TMP}/upgrade-install1.log"
tr -d "'" < "$upgrade_hook" > "${TMP}/unquoted.json"
cp "${TMP}/unquoted.json" "$upgrade_hook"
sl_install_into "${TMP}/upgrade-install2.log"
check "quoting upgrade: reported as stale, not as user-modified" "1" \
    "$(grep -c 'UPDATED (was stale)' "${TMP}/upgrade-install2.log" || true)"
check "quoting upgrade: no 'had local modifications'" "0" \
    "$(grep -c 'had local modifications' "${TMP}/upgrade-install2.log" || true)"
check "quoting upgrade: no backup file left behind" "0" \
    "$(find "${upgrade_home}/.copilot/hooks" -name '*.bak-*' | wc -l | tr -d ' ')"
# The store did not move, so the stale message must not claim it did. The
# relocation wording here would read "(previously <the identical path>)" -- a
# line that tells the user nothing changed while announcing a change.
check "quoting upgrade: message says the location is unchanged" "1" \
    "$(grep -c 'same location' "${TMP}/upgrade-install2.log" || true)"
check "quoting upgrade: no 'previously <same path>' line" "0" \
    "$(grep -c 'previously ' "${TMP}/upgrade-install2.log" || true)"
# Idempotent: the run after the re-render has nothing left to do. A canonical
# comparison that quietly re-rendered on every install would still pass the
# three checks above.
sl_install_into "${TMP}/upgrade-install3.log"
check "quoting upgrade: next run reports up to date" "1" \
    "$(grep -c 'Up to date' "${TMP}/upgrade-install3.log" || true)"

# The counter-case. Same store, same template, one genuine edit (a changed
# timeout -- nowhere near the path), and the classification must go the other
# way: backed up, and the user told.
sed 's/"timeoutSec": 30/"timeoutSec": 60/' "$upgrade_hook" > "${TMP}/edited-hook.json"
check "edited fixture actually differs" "differs" \
    "$([[ "$(cat "${TMP}/edited-hook.json")" == "$(cat "$upgrade_hook")" ]] && echo same || echo differs)"
cp "${TMP}/edited-hook.json" "$upgrade_hook"
sl_install_into "${TMP}/upgrade-install4.log"
check "genuine edit: still reported as user-modified" "1" \
    "$(grep -c 'had local modifications' "${TMP}/upgrade-install4.log" || true)"
check "genuine edit: backup kept" "1" \
    "$(find "${upgrade_home}/.copilot/hooks" -name '*.bak-*' | wc -l | tr -d ' ')"
check "genuine edit: backup holds the user's version" "1" \
    "$(grep -c '"timeoutSec": 60' "${upgrade_home}"/.copilot/hooks/*.bak-* || true)"

# The hook actually installed at the end must still name a real, existing
# script -- the point of all of the above.
hook="${TMP}/home-space/.copilot/hooks/self-learning.json"
check "final hook parses as JSON" "yes" \
    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("yes")' "$hook" 2>/dev/null || echo no)"
# Tokenize in Python (quoting-aware), but test EXISTENCE in bash.
#
# MEASURED: doing the existence check in Python failed on both windows-latest
# cells (runs 30376530556 and 30379317060) while every bash `[[ -f ]]` check in
# this same file passed. The path is built by bash and is MSYS-form
# (/tmp/... or /c/Users/...); python3 under Git Bash is a NATIVE Windows binary
# and os.path.isfile() cannot resolve that spelling. Same boundary that forced
# render-template.py to take its replacement on stdin -- see its header.
_hook_cmd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["sessionEnd"][0]["bash"])' "$hook" 2>/dev/null || true)"
_hook_script="$(sl_hook_script_path "$_hook_cmd")"
check "final hook names an existing script" "yes" \
    "$([[ -n "$_hook_script" && -f "$_hook_script" ]] && echo yes || echo no)"

if [[ $FAILURES -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (${FAILURES} failure(s))"
    exit 1
fi
