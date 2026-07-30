#!/usr/bin/env bash
# tests/test-mirror-skills.sh
#
# Route A. The properties that matter are not "does it copy a file" but the two
# that make writing into the USER'S OWN directory acceptable: it never touches
# anything it did not create, and it removes exactly what it did.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="${SCRIPT_DIR}/scripts/mirror-skills.py"
MARKER=".self-learning-managed"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Fully sandboxed HOME: this script writes into $HOME/.claude and $HOME/.copilot
# by design, so an unsandboxed run would edit the developer's real skills.
setup() {
    HOME_DIR=$(mktemp -d)
    STORE="${HOME_DIR}/store"
    mkdir -p "${STORE}/learned-skills" "${HOME_DIR}/.claude/skills"
}
add_skill() {  # add_skill <name> <description>
    mkdir -p "${STORE}/learned-skills/$1"
    printf -- '---\nname: %s\ndescription: %s\n---\nBody for %s\n' "$1" "$2" "$1" \
        > "${STORE}/learned-skills/$1/SKILL.md"
}
run_mirror() {
    env -i HOME="$HOME_DIR" AGENT_LEARNING_HOME="$STORE" PATH="$PATH" \
        python3 "$MIRROR" "$@"
}

# ---------------------------------------------------------------------------
# A) A learned skill reaches the harness-native location.
# ---------------------------------------------------------------------------
setup
add_skill "probe-before-inferring" "Probe the platform, never infer from its name."
run_mirror > /dev/null
TARGET="${HOME_DIR}/.claude/skills/probe-before-inferring"
check "A: skill directory created in the harness location" "yes" \
    "$([[ -f "${TARGET}/SKILL.md" ]] && echo yes || echo no)"
# cmp, not md5sum: macOS ships `md5` and has no `md5sum`, so an md5sum here
# fails on both macos-latest CI cells. cmp also answers the actual question --
# are these bytes identical -- without a hash in between.
check "A: content matches the store copy byte for byte" "yes" \
    "$(cmp -s "${STORE}/learned-skills/probe-before-inferring/SKILL.md" \
              "${TARGET}/SKILL.md" && echo yes || echo no)"
check "A: marker written" "yes" "$([[ -f "${TARGET}/${MARKER}" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# B) Idempotent. This runs on every session start, so a second pass must not
#    rewrite the file -- an mtime churn would look like activity that isn't.
# ---------------------------------------------------------------------------
BEFORE=$(stat -c %Y "${TARGET}/SKILL.md" 2>/dev/null || stat -f %m "${TARGET}/SKILL.md")
sleep 1
OUT=$(run_mirror)
AFTER=$(stat -c %Y "${TARGET}/SKILL.md" 2>/dev/null || stat -f %m "${TARGET}/SKILL.md")
check "B: second run reports unchanged" "yes" \
    "$(printf '%s' "$OUT" | grep -q 'unchanged=1' && echo yes || echo no)"
check "B: file not rewritten (mtime stable)" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
# C) THE SAFETY PROPERTY. A user-authored skill of the same name is never
#    touched. ~/.claude/skills is the user's namespace and already held 21
#    hand-written skills when this was built.
# ---------------------------------------------------------------------------
setup
add_skill "collision" "Ours."
USERS="${HOME_DIR}/.claude/skills/collision"
mkdir -p "$USERS"
printf 'MY OWN HAND-WRITTEN SKILL\n' > "${USERS}/SKILL.md"
# cksum: POSIX, unlike md5sum. See case A.
USER_SUM=$(cksum < "${USERS}/SKILL.md")
OUT=$(run_mirror)
check "C: user's file left byte-identical" "$USER_SUM" "$(cksum < "${USERS}/SKILL.md")"
check "C: no marker planted in the user's directory" "no" \
    "$([[ -f "${USERS}/${MARKER}" ]] && echo yes || echo no)"
check "C: the collision is reported, not silent" "yes" \
    "$(printf '%s' "$OUT" | grep -q 'not created by us' && echo yes || echo no)"

# ---------------------------------------------------------------------------
# D) Pruning. curator-run.sh archives and DELETES skills, so a mirror that only
#    ever adds would advertise an archived skill forever. Hermes invalidates its
#    skill snapshot from six call sites to avoid exactly this staleness.
# ---------------------------------------------------------------------------
setup
add_skill "keep-me" "Stays."
add_skill "delete-me" "Will be archived."
run_mirror > /dev/null
check "D: both mirrored initially" "2" \
    "$(find "${HOME_DIR}/.claude/skills" -name SKILL.md | wc -l | tr -d ' ')"
rm -rf "${STORE}/learned-skills/delete-me"
OUT=$(run_mirror)
check "D: removed-from-store skill is pruned" "no" \
    "$([[ -d "${HOME_DIR}/.claude/skills/delete-me" ]] && echo yes || echo no)"
check "D: the surviving skill is still there" "yes" \
    "$([[ -f "${HOME_DIR}/.claude/skills/keep-me/SKILL.md" ]] && echo yes || echo no)"
check "D: pruning is reported" "yes" \
    "$(printf '%s' "$OUT" | grep -q 'pruned=1' && echo yes || echo no)"

# ---------------------------------------------------------------------------
# E) Pruning must NEVER delete an unmarked directory. This is the destructive
#    half of the safety property and deserves its own case.
# ---------------------------------------------------------------------------
setup
add_skill "ours" "Ours."
mkdir -p "${HOME_DIR}/.claude/skills/theirs"
printf 'hand written\n' > "${HOME_DIR}/.claude/skills/theirs/SKILL.md"
run_mirror > /dev/null
check "E: unmarked directory with no store counterpart survives pruning" "yes" \
    "$([[ -f "${HOME_DIR}/.claude/skills/theirs/SKILL.md" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# F) Targets are PROBED. A harness that is not installed gets no directory --
#    creating ~/.copilot on a machine without Copilot is exactly the
#    wrong-location state paths.py exists to prevent.
# ---------------------------------------------------------------------------
setup   # creates ~/.claude only; no ~/.copilot
add_skill "probed" "Only where a harness lives."
run_mirror > /dev/null
check "F: absent harness root is not created" "no" \
    "$([[ -e "${HOME_DIR}/.copilot" ]] && echo yes || echo no)"
mkdir -p "${HOME_DIR}/.copilot"
run_mirror > /dev/null
check "F: present harness root IS used" "yes" \
    "$([[ -f "${HOME_DIR}/.copilot/skills/probed/SKILL.md" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# G) An empty store is not an error, and a store with nothing to mirror must not
#    fail a session-start hook.
# ---------------------------------------------------------------------------
setup
run_mirror > /dev/null; rc=$?
check "G: empty store exits 0" "0" "$rc"

# ---------------------------------------------------------------------------
# H) No home directory at all must be a REPORTED failure, not a traceback.
#
#    This is the windows-latest regression. The mirror roots were once
#    module-level constants built from `Path.home()`, which RAISES rather than
#    returning None -- so merely IMPORTING the module under `env -i` with no
#    HOME and no USERPROFILE died at import time on both Windows cells:
#
#      File "scripts/mirror-skills.py", line 56, in <module>
#      File ".../pathlib/_local.py", line 808, in expanduser
#      RuntimeError: Could not determine home directory.
#
#    Windows is where this surfaces because Path.home() consults USERPROFILE
#    first there, and the sandbox sets only HOME. The roots are now resolved
#    lazily, HOME is consulted explicitly and first (so a sandboxed run can
#    never mirror into the developer's real Windows profile), and an
#    unresolvable home exits 1 with a reason.
NO_HOME_OUT=$(env -i PATH="$PATH" python3 "$MIRROR" 2>&1 || true)
# `|| NO_HOME_RC=$?` and not a bare call: this command is EXPECTED to fail, and
# under `set -e` a bare failing command aborts the whole suite -- which it did,
# reporting 16 passes, 0 failures and exit 1, a shape that looks like success
# with a stray error rather than "the rest never ran".
NO_HOME_RC=0
env -i PATH="$PATH" python3 "$MIRROR" > /dev/null 2>&1 || NO_HOME_RC=$?
check "H: no resolvable home exits 1, not a crash" "1" "$NO_HOME_RC"
check "H: and says why" "yes" \
    "$(printf '%s' "$NO_HOME_OUT" | grep -qi 'cannot resolve' && echo yes || echo no)"
check "H: no Python traceback reaches the user" "no" \
    "$(printf '%s' "$NO_HOME_OUT" | grep -q 'Traceback' && echo yes || echo no)"

# The module must also IMPORT cleanly with no home vars -- that is what actually
# broke, and it is a different failure from main() returning 1.
IMPORT_RC=0
env -i PATH="$PATH" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', '${MIRROR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
" > /dev/null 2>&1 || IMPORT_RC=$?
check "H: module imports with no HOME and no USERPROFILE" "0" "$IMPORT_RC"

# I) HOME must WIN over USERPROFILE.
#
#    This is the mutation-detectable half of case H, and the one with teeth: if
#    resolution consulted Path.home() first, then on Windows -- where
#    Path.home() prefers USERPROFILE -- a sandboxed test or a hard-rule-1
#    sandboxed run would mirror into the developer's REAL profile while
#    believing it was contained. Case H alone cannot catch that on Linux,
#    because Path.home() there falls back to the passwd entry and succeeds.
setup
add_skill "home-wins" "HOME must be preferred over USERPROFILE."
DECOY=$(mktemp -d)
mkdir -p "${DECOY}/.claude/skills"
env -i HOME="$HOME_DIR" USERPROFILE="$DECOY" AGENT_LEARNING_HOME="$STORE" PATH="$PATH" \
    python3 "$MIRROR" --quiet
check "I: mirrored under HOME" "yes" \
    "$([[ -f "${HOME_DIR}/.claude/skills/home-wins/SKILL.md" ]] && echo yes || echo no)"
check "I: NOT mirrored under USERPROFILE" "no" \
    "$([[ -e "${DECOY}/.claude/skills/home-wins" ]] && echo yes || echo no)"
rm -rf "$DECOY"

rm -rf "$HOME_DIR"
if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All mirror-skills tests passed."
