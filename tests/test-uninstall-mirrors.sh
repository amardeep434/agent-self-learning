#!/usr/bin/env bash
# tests/test-uninstall-mirrors.sh
#
# uninstall.sh's mirrored-skill removal is a DELETE LOOP OVER THE USER'S OWN
# DIRECTORIES (~/.claude/skills, ~/.copilot/skills). It had no test of any kind:
# `grep -rl self-learning-managed tests/` matched only tests/test-mirror-skills.sh,
# which exercises scripts/mirror-skills.py -- never uninstall's copy of the rule.
#
# That copy was the WEAK form:
#
#     if [[ -f "${_dir}.self-learning-managed" ]]; then remove "${_dir%/}"; fi
#
# i.e. exactly the filename-existence test that mirror-skills.py's is_ours() was
# forced to abandon after an adversarial review destroyed real directories with
# it three ways (renamed user copy carrying a valid marker; hand-dropped file of
# that documented name; SYMLINK, because `.is_file()` follows links). The
# hardening landed in is_ours() and never reached uninstall.sh -- so the delete
# loop pointed at the user's namespace was running the rule that had already been
# shown to destroy data. Cases C-F below are that review, re-run against
# uninstall.sh.
#
# Every mirror here is created by running mirror-skills.py for real, so the
# "genuine" case has genuine provenance rather than a hand-written marker that
# assumes what the marker looks like.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="${SCRIPT_DIR}/scripts/mirror-skills.py"
MARKER=".self-learning-managed"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
# Checksum of a whole directory tree. Compared before and after, never "is it
# still there" -- this project's own rule after a `find … || echo none` check
# reported "nothing changed" for a run that had changed things. A missing
# directory answers GONE, which can never accidentally equal a real checksum.
tree_sum() { [[ -d "$1" ]] || { echo GONE; return; }; find "$1" -type f -exec cksum {} + | sort | cksum; }

# Fully sandboxed: hard rule 1. This script's subject deletes directories under
# $HOME, so an unsandboxed run would delete the developer's real skills.
setup() {
    HOME_DIR=$(mktemp -d)
    STORE="${HOME_DIR}/store"
    mkdir -p "${STORE}/learned-skills" "${HOME_DIR}/.claude/skills"
}
add_skill() {  # add_skill <name>
    mkdir -p "${STORE}/learned-skills/$1"
    printf -- '---\nname: %s\ndescription: Skill %s.\n---\nBody for %s\n' "$1" "$1" "$1" \
        > "${STORE}/learned-skills/$1/SKILL.md"
}
run_mirror() {
    env -i HOME="$HOME_DIR" AGENT_LEARNING_HOME="$STORE" PATH="$PATH" \
        SL_CONFIG_FILE=/nonexistent python3 "$MIRROR" "$@"
}
run_uninstall() {  # run_uninstall [--keep-data] ; echoes stdout+stderr
    env -i HOME="$HOME_DIR" AGENT_LEARNING_HOME="$STORE" PATH="$PATH" \
        SL_CONFIG_FILE=/nonexistent bash "${SCRIPT_DIR}/uninstall.sh" --yes "$@" 2>&1
}

# ---------------------------------------------------------------------------
# A) A genuinely mirrored directory IS removed -- including with --keep-data.
#    The mirror is a DELIVERY artifact; the store copy is the data. Leaving the
#    mirror behind would have the harness keep auto-loading learned skills with
#    nothing left to update or prune them.
# ---------------------------------------------------------------------------
setup
add_skill "genuine"
mkdir -p "${HOME_DIR}/.copilot/skills"
run_mirror > /dev/null
check "A: precondition - mirror exists in the claude root" "yes" \
    "$(exists "${HOME_DIR}/.claude/skills/genuine/SKILL.md")"
check "A: precondition - mirror exists in the copilot root" "yes" \
    "$(exists "${HOME_DIR}/.copilot/skills/genuine/SKILL.md")"
OUT_A=$(run_uninstall --keep-data)
check "A: mirrored directory removed from the claude root" "no" \
    "$(exists "${HOME_DIR}/.claude/skills/genuine")"
check "A: mirrored directory removed from the copilot root" "no" \
    "$(exists "${HOME_DIR}/.copilot/skills/genuine")"
# --keep-data preserves the DATA, which is the store copy, not the mirror.
check "A: --keep-data preserved the store copy of the skill" "yes" \
    "$(exists "${STORE}/learned-skills/genuine/SKILL.md")"
# Reported by path, not by prose: the removal names each directory it deleted.
check "A: removal names the claude directory it deleted" "yes" \
    "$(printf '%s' "$OUT_A" | grep -Fq "${HOME_DIR}/.claude/skills/genuine" && echo yes || echo no)"
check "A: removal names the copilot directory it deleted" "yes" \
    "$(printf '%s' "$OUT_A" | grep -Fq "${HOME_DIR}/.copilot/skills/genuine" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# B) --keep-data removes mirrors but preserves the whole store.
#    Asserted by CHECKSUM over the store, not by "does a file exist" -- this
#    project's own rule after a `find ... || echo none` check reported "nothing
#    changed" for a run that had changed things.
# ---------------------------------------------------------------------------
setup
add_skill "kept"
mkdir -p "${STORE}/memory"
printf -- '- A lesson worth keeping.\n' > "${STORE}/memory/MEMORY.md"
run_mirror > /dev/null
STORE_SUM_BEFORE=$(tree_sum "$STORE")
run_uninstall --keep-data > /dev/null
check "B: mirror removed under --keep-data" "no" \
    "$(exists "${HOME_DIR}/.claude/skills/kept")"
check "B: store byte-identical under --keep-data" "$STORE_SUM_BEFORE" \
    "$(tree_sum "$STORE")"

# ---------------------------------------------------------------------------
# C) An unmarked, hand-written skill is NEVER touched. ~/.claude/skills is the
#    user's own namespace and holds 22 hand-written skills on the machine this
#    was written on.
# ---------------------------------------------------------------------------
setup
mkdir -p "${HOME_DIR}/.claude/skills/hand-written/references"
printf 'MY OWN SKILL\n' > "${HOME_DIR}/.claude/skills/hand-written/SKILL.md"
printf 'notes\n' > "${HOME_DIR}/.claude/skills/hand-written/references/notes.md"
HAND_SUM=$(tree_sum "${HOME_DIR}/.claude/skills/hand-written")
run_uninstall > /dev/null
check "C: unmarked hand-written skill survives, byte-identical" "$HAND_SUM" \
    "$(tree_sum "${HOME_DIR}/.claude/skills/hand-written")"

# ---------------------------------------------------------------------------
# D) FORGED / PARTIAL MARKERS. Destruction (b) from the mirror-skills.py review:
#    the marker filename is documented in README.md and in uninstall.sh itself,
#    so a user who reads either can drop a file of that name into a skill --
#    or a mirrored marker can be copied into a directory it does not describe.
#    Neither may make a directory deletable.
# ---------------------------------------------------------------------------
setup
add_skill "template"
run_mirror > /dev/null
# D1: empty marker -- the "someone dropped a file of that name" case.
mkdir -p "${HOME_DIR}/.claude/skills/empty-marker"
printf 'mine\n' > "${HOME_DIR}/.claude/skills/empty-marker/SKILL.md"
: > "${HOME_DIR}/.claude/skills/empty-marker/${MARKER}"

# D2: signature present, `skill:` line absent -- a partial forgery.
mkdir -p "${HOME_DIR}/.claude/skills/no-name-line"
printf 'mine\n' > "${HOME_DIR}/.claude/skills/no-name-line/SKILL.md"
printf 'agent-self-learning:mirrored-skill\nManaged by something.\n' \
    > "${HOME_DIR}/.claude/skills/no-name-line/${MARKER}"

# D3: a VALID marker naming a DIFFERENT directory -- the renamed-copy case. This
#     is destruction (a): the ordinary "copy a learned skill to customise it"
#     workflow produces exactly this, and the marker inside it is genuine.
cp -r "${HOME_DIR}/.claude/skills/template" "${HOME_DIR}/.claude/skills/my-customised-copy"
printf 'my edits\n' >> "${HOME_DIR}/.claude/skills/my-customised-copy/SKILL.md"

# D4: signature line present but WRONG name explicitly spelled out.
mkdir -p "${HOME_DIR}/.claude/skills/wrong-name-line"
printf 'mine\n' > "${HOME_DIR}/.claude/skills/wrong-name-line/SKILL.md"
printf 'agent-self-learning:mirrored-skill\nskill: some-other-skill\n' \
    > "${HOME_DIR}/.claude/skills/wrong-name-line/${MARKER}"

FORGED_NAMES=(empty-marker no-name-line my-customised-copy wrong-name-line)
FORGED_SUMS=()
for _forged in "${FORGED_NAMES[@]}"; do
    FORGED_SUMS+=("$(tree_sum "${HOME_DIR}/.claude/skills/${_forged}")")
done
run_uninstall > /dev/null
_i=0
for _forged in "${FORGED_NAMES[@]}"; do
    check "D: '${_forged}' survives, byte-identical (forged/partial marker is not provenance)" \
        "${FORGED_SUMS[$_i]}" "$(tree_sum "${HOME_DIR}/.claude/skills/${_forged}")"
    _i=$((_i + 1))
done
# And the genuine one in the same run WAS removed -- otherwise every assertion
# above would also pass for an uninstall that simply deletes nothing.
check "D: the genuine mirror in the same run was still removed" "no" \
    "$(exists "${HOME_DIR}/.claude/skills/template")"

# ---------------------------------------------------------------------------
# E) A SYMLINKED marker does not make a directory deletable. Destruction (c):
#    `[[ -f ... ]]` and Python's `.is_file()` both FOLLOW symlinks, so a link to
#    a valid marker satisfied the old gate. The link target here is a genuine
#    marker naming this very directory, so symlink-ness is the ONLY thing that
#    may reject it.
# ---------------------------------------------------------------------------
setup
add_skill "template"
run_mirror > /dev/null
mkdir -p "${HOME_DIR}/bait" "${HOME_DIR}/.claude/skills/symlink-bait"
printf 'mine\n' > "${HOME_DIR}/.claude/skills/symlink-bait/SKILL.md"
printf 'agent-self-learning:mirrored-skill\nskill: symlink-bait\n' > "${HOME_DIR}/bait/marker"
if ln -s "${HOME_DIR}/bait/marker" "${HOME_DIR}/.claude/skills/symlink-bait/${MARKER}" 2>/dev/null \
   && [[ -L "${HOME_DIR}/.claude/skills/symlink-bait/${MARKER}" ]]; then
    # PROBED, not assumed: symlink creation fails on Windows without developer
    # mode / SeCreateSymbolicLinkPrivilege, and a skip must print its own reason.
    check "E: precondition - the symlinked marker satisfies the OLD weak gate" "yes" \
        "$([[ -f "${HOME_DIR}/.claude/skills/symlink-bait/${MARKER}" ]] && echo yes || echo no)"
    BAIT_SUM=$(cksum < "${HOME_DIR}/.claude/skills/symlink-bait/SKILL.md")
    run_uninstall > /dev/null
    check "E: symlinked marker does NOT make the directory deletable" "yes" \
        "$(exists "${HOME_DIR}/.claude/skills/symlink-bait/SKILL.md")"
    check "E: and the user's file is byte-identical" "$BAIT_SUM" \
        "$(cksum < "${HOME_DIR}/.claude/skills/symlink-bait/SKILL.md")"
    check "E: the genuine mirror in the same run was still removed" "no" \
        "$(exists "${HOME_DIR}/.claude/skills/template")"
else
    echo "SKIP: E (symlink creation is not permitted here — probed by attempting" \
         "\`ln -s\` and finding no symlink at the destination; on Windows this" \
         "needs developer mode or SeCreateSymbolicLinkPrivilege)"
fi

# ---------------------------------------------------------------------------
# F) A directory-symlink pointing INTO the store must not be followed. Deleting
#    through it would delete the store copy -- the data -- under --keep-data.
#
#    Scope of what this proves, MEASURED rather than claimed. Removing the
#    `child.is_symlink()` guard does NOT turn this case red: shutil.rmtree
#    refuses a symlink outright --
#
#      >>> shutil.rmtree(link)
#      OSError: [Errno None] None: PosixPath('/tmp/…/link')   # target intact
#
#    -- so the store is protected twice over and the guard is defence in depth,
#    not the sole barrier. What this case DOES kill is any change that resolves
#    the path before deleting (`shutil.rmtree(child.resolve())` was applied and
#    failed this assertion), which is the realistic way the protection gets lost.
# ---------------------------------------------------------------------------
setup
add_skill "linked"
run_mirror > /dev/null
rm -rf "${HOME_DIR}/.claude/skills/linked"
if ln -s "${STORE}/learned-skills/linked" "${HOME_DIR}/.claude/skills/linked" 2>/dev/null \
   && [[ -L "${HOME_DIR}/.claude/skills/linked" ]]; then
    printf 'agent-self-learning:mirrored-skill\nskill: linked\n' \
        > "${STORE}/learned-skills/linked/${MARKER}"
    run_uninstall --keep-data > /dev/null
    check "F: store contents behind a directory symlink are untouched" "yes" \
        "$(exists "${STORE}/learned-skills/linked/SKILL.md")"
else
    echo "SKIP: F (symlink creation is not permitted here — probed by attempting" \
         "\`ln -s\` and finding no symlink at the destination)"
fi

# ---------------------------------------------------------------------------
# G) With nothing to remove, uninstall must SAY so. "found none" and "did not
#    look" are different outcomes and this line is what distinguishes them --
#    the same distinction doctor.sh draws between an absent and an empty log.
# ---------------------------------------------------------------------------
setup
OUT_G=$(run_uninstall)
check "G: says no marker-managed mirrors were found" "yes" \
    "$(printf '%s' "$OUT_G" | grep -Fq 'no marker-managed mirrored skills found' && echo yes || echo no)"
# Differential: the same run WITH a mirror must not print that line, or the line
# above proves nothing about whether anything was looked at.
setup
add_skill "present"
run_mirror > /dev/null
OUT_G2=$(run_uninstall)
check "G: does NOT say that when a mirror was found and removed" "no" \
    "$(printf '%s' "$OUT_G2" | grep -Fq 'no marker-managed mirrored skills found' && echo yes || echo no)"

# ---------------------------------------------------------------------------
# H) DEGRADED PATH. The gate can only be evaluated with python3. Without it,
#    uninstall must delete NOTHING and say why -- falling back to a filename
#    test would be choosing the exact rule that destroyed data (hard rule 2:
#    a degraded outcome gets a named reason, never a silent one).
# ---------------------------------------------------------------------------
setup
add_skill "orphaned"
run_mirror > /dev/null
NOPY_BIN="${HOME_DIR}/nopy"
mkdir -p "$NOPY_BIN"
for _tool in bash sh dirname basename pwd grep sed date rm mkdir cp mv ls cat jq find chmod tr uname; do
    _p=$(command -v "$_tool" 2>/dev/null) && ln -s "$_p" "${NOPY_BIN}/${_tool}" 2>/dev/null || true
done
if command -v python3 >/dev/null 2>&1 && ! env -i HOME="$HOME_DIR" PATH="$NOPY_BIN" \
        sh -c 'command -v python3' >/dev/null 2>&1; then
    # PROBED: python3 really is absent from the reduced PATH.
    OUT_H=$(env -i HOME="$HOME_DIR" AGENT_LEARNING_HOME="$STORE" PATH="$NOPY_BIN" \
        SL_CONFIG_FILE=/nonexistent bash "${SCRIPT_DIR}/uninstall.sh" --yes 2>&1 || true)
    check "H: without python3 the mirror is NOT deleted" "yes" \
        "$(exists "${HOME_DIR}/.claude/skills/orphaned/SKILL.md")"
    check "H: and the reason names the marker file to look for" "yes" \
        "$(printf '%s' "$OUT_H" | grep -Fq "$MARKER" && echo yes || echo no)"
    check "H: and does not claim there were none to find" "no" \
        "$(printf '%s' "$OUT_H" | grep -Fq 'no marker-managed mirrored skills found' && echo yes || echo no)"
else
    echo "SKIP: H (could not build a PATH without python3 — probed with" \
         "\`command -v python3\` under the reduced PATH and it was still found," \
         "or python3 is absent from this machine entirely)"
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All uninstall mirror-removal tests passed."
