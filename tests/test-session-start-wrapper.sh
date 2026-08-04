#!/usr/bin/env bash
# tests/test-session-start-wrapper.sh
#
# Tests scripts/session-start-context.sh -- the file all three configs actually
# register. It had NO tests: test-session-start-context.sh runs the .py directly,
# so two real defects lived in the gap and shipped green.
#
#   1. `set -e` + a bare `python3 ...` call meant a nonzero exit from the
#      injector aborted the wrapper THERE. The mirror launch and the wrapper's
#      own `exit` were unreachable, so Route A was silently killed whenever
#      Route B failed -- the exact coupling the detached launch exists to avoid.
#   2. The python3-missing branch printed nothing on stdout, violating the
#      "exactly one JSON object" contract the .py goes to lengths to guarantee.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${SCRIPT_DIR}/scripts/session-start-context.sh"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

PAYLOAD='{"session_id":"a","transcript_path":"/tmp/t","source":"startup"}'

new_home() {
    local h; h=$(mktemp -d)
    mkdir -p "$h/store/memory" "$h/store/logs" "$h/store/learned-skills/mirrored-skill" "$h/.claude/skills"
    echo "- A lesson worth delivering." > "$h/store/memory/MEMORY.md"
    printf -- '---\nname: mirrored-skill\ndescription: d\n---\nBody\n' \
        > "$h/store/learned-skills/mirrored-skill/SKILL.md"
    printf '%s' "$h"
}

# ---------------------------------------------------------------------------
# A) Happy path: one JSON object on stdout, and the mirror runs.
# ---------------------------------------------------------------------------
H=$(new_home)
OUT=$(printf '%s' "$PAYLOAD" | env -i HOME="$H" AGENT_LEARNING_HOME="$H/store" PATH="$PATH" bash "$WRAPPER")
check "A: exactly one line on stdout" "1" "$(printf '%s' "$OUT" | grep -c '')"
check "A: stdout is one JSON object" "dict" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(type(json.load(sys.stdin)).__name__)' 2>/dev/null || echo PARSE_FAILED)"
sleep 2
check "A: the detached mirror published the skill" "yes" \
    "$([[ -f "$H/.claude/skills/mirrored-skill/SKILL.md" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# B) THE set -e DEFECT. When the injector exits nonzero, Route A must still run.
#    A stub replaces the .py so the failure is deterministic and has nothing to
#    do with the store's contents.
# ---------------------------------------------------------------------------
H2=$(new_home)
STUB_DIR=$(mktemp -d)
# mirror-skills.py gates bodies through inject-agents-md.py, which loads
# scan-threats.py. Both must be present or the mirror fails CLOSED and
# publishes nothing -- correct behaviour, but it would make this case test
# the stub instead of the wrapper.
cp "${SCRIPT_DIR}/scripts/session-start-context.sh" \
   "${SCRIPT_DIR}/scripts/mirror-skills.py" \
   "${SCRIPT_DIR}/scripts/inject-agents-md.py" \
   "${SCRIPT_DIR}/scripts/scan-threats.py" "$STUB_DIR/"
# lib/*.sh as well as lib/*.py: the wrapper sources lib/python-resolve.sh
# (the one interpreter resolver) before it can run anything at all.
mkdir -p "$STUB_DIR/lib"; cp "${SCRIPT_DIR}"/scripts/lib/*.py "${SCRIPT_DIR}"/scripts/lib/*.sh "$STUB_DIR/lib/" 2>/dev/null || true
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' > "$STUB_DIR/session-start-context.py"
RC=0
printf '%s' "$PAYLOAD" | env -i HOME="$H2" AGENT_LEARNING_HOME="$H2/store" PATH="$PATH" \
    bash "$STUB_DIR/session-start-context.sh" > /dev/null 2>&1 || RC=$?
check "B: the injector's exit status is propagated, not swallowed" "3" "$RC"
sleep 2
check "B: Route A still ran even though Route B failed" "yes" \
    "$([[ -f "$H2/.claude/skills/mirrored-skill/SKILL.md" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# C) python3 absent: stdout must STILL carry one JSON object.
#    Probed, not assumed -- if a PATH without python3 cannot be built on this
#    machine, say so rather than asserting through it.
# ---------------------------------------------------------------------------
NOPY_DIR=$(mktemp -d)
for tool in bash grep sed dirname cd; do
    src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$NOPY_DIR/$tool" 2>/dev/null || true
done
# TWO probes, because one was not enough. The stripped PATH must (a) not reach
# python3 -- otherwise the case is meaningless -- AND (b) still reach a working
# bash, or the wrapper never executes and its empty output gets misread as a
# contract violation. That is exactly what happened on both windows-latest cells:
# Git Bash's `ln -s` does not produce working symlinks without Developer Mode, so
# NOPY_DIR had no usable bash either and case C failed with '' where it expected
# '{}' -- reporting a product defect that was really a broken fixture.
NOPY_HAS_PYTHON=no
env -i PATH="$NOPY_DIR" command -v python3 >/dev/null 2>&1 && NOPY_HAS_PYTHON=yes
NOPY_HAS_BASH=no
env -i PATH="$NOPY_DIR" bash -c 'exit 0' >/dev/null 2>&1 && NOPY_HAS_BASH=yes
if [[ "$NOPY_HAS_PYTHON" == "yes" ]]; then
    echo "SKIP: python3-absent case -- probed: python3 is still reachable on the stripped PATH"
elif [[ "$NOPY_HAS_BASH" != "yes" ]]; then
    echo "SKIP: python3-absent case -- probed: a stripped PATH with a WORKING bash could not" \
         "be built here (\`env -i PATH=$NOPY_DIR bash -c 'exit 0'\` failed), so the wrapper" \
         "cannot be executed to observe its stdout. Common on Git Bash, where 'ln -s' does" \
         "not create real symlinks without Developer Mode."
else
    H3=$(new_home)
    NOPY_OUT=$(printf '%s' "$PAYLOAD" | env -i HOME="$H3" AGENT_LEARNING_HOME="$H3/store" \
        PATH="$NOPY_DIR" bash "$WRAPPER" 2>/dev/null || true)
    check "C: python3 absent still emits one JSON object on stdout" "{}" "$NOPY_OUT"
    rm -rf "$H3"
fi

rm -rf "$H" "$H2" "$STUB_DIR" "$NOPY_DIR"
if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All session-start-wrapper tests passed."
