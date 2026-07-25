#!/usr/bin/env bash
# tests/test-skill-layout-pinning.sh
#
# Item 1: the on-disk skill layout (<skills_dir>/<name>/SKILL.md, the shared
# .usage.json, the .archive dir) has one definition: scripts/lib/skill_layout.py
# (Python) / scripts/lib/skill-layout.sh (bash CLI wrapper over it). Five
# consumers used to re-state it independently -- persist-proposal.py,
# skill-lifecycle.py, inject-agents-md.py, curator-run.sh, self-learning-health.sh
# -- and that exact duplication already produced a Critical on this branch
# once (a flat `<name>.md` writer against three directory-shaped readers, fix
# round B). This test is the guard: it fails if ANY of the five consumers
# starts spelling "SKILL.md" / ".usage.json" / ".archive" as a local literal
# again, instead of reading it from the shared module.
#
# Two halves:
#   1. Behavioral: prove skill_layout.py's constants are what every consumer
#      actually resolves to, and that persist-proposal.py's own aliases trace
#      back to the module (not a re-typed literal) by identity check.
#   2. Source-pin: a literal-usage grep over the five consumer files, in the
#      style of tests/test-script-paths.sh's exemption-list pattern -- zero
#      tolerance here (no consumer has a legitimate reason to hardcode this
#      layout), so any hit is an unconditional FAIL, not an exemptable one.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

## ============================================================
## 1. Behavioral: skill_layout.py is the ground truth every consumer reads.
## ============================================================

LAYOUT_ALL="$(python3 "${SCRIPT_DIR}/scripts/lib/skill_layout.py" all)"
check "skill_layout.py 'all' reports skill_md_filename=SKILL.md" "yes" \
    "$(printf '%s\n' "$LAYOUT_ALL" | grep -qF "skill_md_filename=SKILL.md" && echo yes || echo no)"
check "skill_layout.py 'all' reports usage_filename=.usage.json" "yes" \
    "$(printf '%s\n' "$LAYOUT_ALL" | grep -qF "usage_filename=.usage.json" && echo yes || echo no)"
check "skill_layout.py 'all' reports archive_dirname=.archive" "yes" \
    "$(printf '%s\n' "$LAYOUT_ALL" | grep -qF "archive_dirname=.archive" && echo yes || echo no)"
check "skill_layout.py 'get skill_md_filename'" "SKILL.md" \
    "$(python3 "${SCRIPT_DIR}/scripts/lib/skill_layout.py" get skill_md_filename)"
check "skill_layout.py 'get usage_filename'" ".usage.json" \
    "$(python3 "${SCRIPT_DIR}/scripts/lib/skill_layout.py" get usage_filename)"
check "skill_layout.py 'get archive_dirname'" ".archive" \
    "$(python3 "${SCRIPT_DIR}/scripts/lib/skill_layout.py" get archive_dirname)"
check "skill_layout.py rejects an unknown key" "2" \
    "$(python3 "${SCRIPT_DIR}/scripts/lib/skill_layout.py" get nope >/dev/null 2>&1; echo $?)"

# Bash CLI wrapper resolves to the exact same values, sourced the same way
# curator-run.sh / self-learning-health.sh source it.
BASH_LAYOUT="$(bash -c "source '${SCRIPT_DIR}/scripts/lib/skill-layout.sh'; echo \"\${SL_SKILL_MD_FILENAME}|\${SL_USAGE_FILENAME}|\${SL_ARCHIVE_DIRNAME}\"")"
check "skill-layout.sh sources the same three values" "SKILL.md|.usage.json|.archive" "$BASH_LAYOUT"

# persist-proposal.py's own module-level aliases must be the SAME objects as
# skill_layout's constants (identity, not merely equal strings) -- proves the
# aliasing is a real import, not a parallel re-typed literal that happens to
# match today.
PP_IDENTITY="$(cd "${SCRIPT_DIR}/scripts" && python3 -c "
import sys
sys.path.insert(0, 'lib')
import skill_layout
import importlib.util
spec = importlib.util.spec_from_file_location('persist_proposal', 'persist-proposal.py')
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)
ok = (pp.SKILL_CONTENT_FILENAME is skill_layout.SKILL_MD_FILENAME
      and pp.USAGE_FILENAME is skill_layout.USAGE_FILENAME)
print('yes' if ok else 'no')
")"
check "persist-proposal.py's filename constants are the skill_layout module's own objects" "yes" "$PP_IDENTITY"

# skill-lifecycle.py's USAGE_FILE/ARCHIVE_DIR must be built from skill_layout's
# helper functions, not a locally re-typed suffix -- prove by monkeypatching
# the module's constants BEFORE skill-lifecycle.py imports it and confirming
# the change propagates. If skill-lifecycle.py ever reverts to a hardcoded
# ".usage.json"/".archive" literal, this assertion goes from PASS to FAIL.
SL_PROPAGATION="$(cd "${SCRIPT_DIR}/scripts" && SL_SKILLS_DIR="$(mktemp -d)" python3 -c "
import sys
sys.path.insert(0, 'lib')
import skill_layout
skill_layout.USAGE_FILENAME = 'MUTATED-usage.json'
skill_layout.ARCHIVE_DIRNAME = 'MUTATED-archive'
import importlib.util
spec = importlib.util.spec_from_file_location('skill_lifecycle', 'skill-lifecycle.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
ok = (mod.USAGE_FILE.name == 'MUTATED-usage.json' and mod.ARCHIVE_DIR.name == 'MUTATED-archive')
print('yes' if ok else 'no')
")"
check "skill-lifecycle.py's USAGE_FILE/ARCHIVE_DIR track a mutated skill_layout module (not a frozen literal)" "yes" "$SL_PROPAGATION"

## ============================================================
## 2. Source-pin: zero tolerance for a re-typed literal in any of the five
## consumers. Unlike test-script-paths.sh's ~/.claude guard, there is no
## legitimate reason for any of these five files to spell the layout
## themselves -- so any hit here is an unconditional FAIL.
## ============================================================

PY_CONSUMERS=(
    "scripts/persist-proposal.py"
    "scripts/skill-lifecycle.py"
    "scripts/inject-agents-md.py"
)
BASH_CONSUMERS=(
    "scripts/curator-run.sh"
    "scripts/self-learning-health.sh"
)

for rel in "${PY_CONSUMERS[@]}"; do
    f="${SCRIPT_DIR}/${rel}"
    hit_count="$(grep -cE '["'"'"']SKILL\.md["'"'"']|["'"'"']\.usage\.json["'"'"']|["'"'"']\.archive["'"'"']' "$f" || true)"
    check "$rel has no re-typed skill-layout literal" "0" "$hit_count"
done

for rel in "${BASH_CONSUMERS[@]}"; do
    f="${SCRIPT_DIR}/${rel}"
    hit_count="$(grep -cE '/SKILL\.md|/\.usage\.json|/\.archive([^A-Za-z0-9_.-]|$)' "$f" || true)"
    check "$rel has no re-typed skill-layout literal" "0" "$hit_count"
done

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "All skill-layout pinning tests passed."
