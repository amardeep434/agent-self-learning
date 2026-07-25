#!/usr/bin/env bash
# tests/test-e2e-skill-visibility.sh
#
# C4: persist-proposal.py used to write a skill as a flat <name>.md file.
# Every consumer (inject-agents-md.py, curator-run.sh, skill-lifecycle.py)
# requires a directory containing SKILL.md. Proven by execution during the
# final review: after the Copilot path end-to-end wrote e2e-copilot-skill.md,
# inject-agents-md.py's managed block did not list it -- the skill the
# pipeline had just persisted was invisible to the very consumer that exists
# to surface it. This suite reproduces that exact end-to-end path and
# asserts the opposite: the just-persisted skill DOES appear.
#
# This is deliberately the full pipeline, not a unit test of one script:
# a fake `copilot` shim stands in for the real CLI (as
# test-copilot-session-review.sh already does), copilot-session-review.sh
# drives it exactly as it would in production, persist-proposal.py is the
# real script (not mocked), and inject-agents-md.py runs against the real,
# resolved store -- so a regression in the contract between any two of
# these scripts fails this suite, not just a narrower unit test.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "PASS: $1"; else echo "FAIL: $1 (did not find '$3')"; FAILURES=$((FAILURES+1)); fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then echo "PASS: $1"; else echo "FAIL: $1 (unexpectedly found '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME" "$FAKE_BIN"' EXIT

SKILLS_DIR="${TMP_HOME}/store/learned-skills"
MEMORY_DIR="${TMP_HOME}/store/memory"

# A fake `copilot` CLI: refuses (with a marker to stderr) if asked for a
# write tool, and otherwise emits a fenced-JSON proposal containing one
# memory entry and one skill -- exactly the OUTPUT CONTRACT
# copilot-session-review.sh's prompt specifies.
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "write" ]]; then
        echo "FAIL_MARKER: write tool was requested" >&2
        exit 3
    fi
done
cat <<'JSON'
```json
{"version": 1,
 "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "e2e-copilot-memory"}],
 "skills": [{"name": "e2e-copilot-skill", "content": "---\nname: e2e-copilot-skill\ndescription: Learned end-to-end during a real pipeline run.\n---\nBody.\n"}]}
```
JSON
FAKE
chmod +x "${FAKE_BIN}/copilot"

# --- Step 1: drive the real end-to-end pipeline (fake copilot -> the real
#     copilot-session-review.sh -> the real persist-proposal.py), against a
#     sandboxed store. Never point AGENT_LEARNING_HOME/HOME at the real one.
env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

# Fix round E: this poll budget used to be 50*0.2s = 10s. copilot-session-review.sh
# runs fully detached (nohup + disown), so the parent returns almost
# immediately and the actual work (spawning the fake copilot, then
# persist-proposal.py) happens asynchronously. Process-spawn overhead on
# windows-latest GitHub Actions runners is well documented as substantially
# higher than Linux/macOS (multiple bash.exe/python.exe launches through
# this one pipeline); 10s is plausible to be too tight there even though
# nothing is actually broken. This is a hypothesis, not confirmed without a
# live Windows run -- widened to 30s and made loud on timeout (a full
# directory listing) so a genuine hang is still visible rather than just
# "the file wasn't there", which looked identical to the timing failure
# from a bare CI log.
_sl_e2e_seeded=0
for _ in $(seq 1 150); do
    if [[ -f "${SKILLS_DIR}/e2e-copilot-skill/SKILL.md" ]]; then
        _sl_e2e_seeded=1
        break
    fi
    sleep 0.2
done
if [[ "$_sl_e2e_seeded" -eq 0 ]]; then
    echo "--- timed out waiting for ${SKILLS_DIR}/e2e-copilot-skill/SKILL.md ---"
    find "${TMP_HOME}/store" 2>&1 || echo "(store not even created)"
fi

check "pipeline wrote the skill as a directory" "yes" \
    "$([[ -f "${SKILLS_DIR}/e2e-copilot-skill/SKILL.md" ]] && echo yes || echo no)"
check "pipeline did NOT write the old flat-file layout" "no" \
    "$([[ -e "${SKILLS_DIR}/e2e-copilot-skill.md" ]] && echo yes || echo no)"
check "pipeline wrote a .usage.json entry, created_by=agent" "agent" \
    "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['e2e-copilot-skill']['created_by'])" "${SKILLS_DIR}/.usage.json" 2>/dev/null || echo MISSING)"
check "pipeline wrote the memory entry too" "e2e-copilot-memory" \
    "$(cat "${MEMORY_DIR}/MEMORY.md" 2>/dev/null || echo MISSING)"

# --- Step 2: the deliverable assertion. Run the REAL inject-agents-md.py
#     against the store the pipeline just populated, and assert the
#     just-persisted skill appears in the managed block. This is the
#     assertion whose absence let the flat-file bug ship: everything above
#     this line could pass (a file gets written, exit 0) while this fails.
AGENTS_MD="${TMP_HOME}/AGENTS.md"
SL_MEMORY_DIR="$MEMORY_DIR" SL_SKILLS_DIR="$SKILLS_DIR" \
    python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "$AGENTS_MD"

BLOCK="$(cat "$AGENTS_MD" 2>/dev/null || echo MISSING)"
contains "just-persisted skill appears in the managed AGENTS.md block" "$BLOCK" "e2e-copilot-skill"
contains "just-persisted skill's description appears" "$BLOCK" "Learned end-to-end during a real pipeline run."
contains "just-persisted memory line appears" "$BLOCK" "e2e-copilot-memory"

# --- Step 3: same check via lib/paths.py's own resolver (no env override),
#     to prove the *default* resolution path (what a real, unconfigured
#     Copilot CLI install would use) also finds the skill -- not just the
#     env-var override path exercised above.
AGENTS_MD2="${TMP_HOME}/AGENTS2.md"
env -i HOME="$TMP_HOME" AGENT_LEARNING_HOME="${TMP_HOME}/store" PATH="$PATH" \
    python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "$AGENTS_MD2"
BLOCK2="$(cat "$AGENTS_MD2" 2>/dev/null || echo MISSING)"
contains "skill visible via paths.py default resolution too (no SL_SKILLS_DIR override)" "$BLOCK2" "e2e-copilot-skill"

# --- Step 4: skill-lifecycle.py (invoked the way curator-run.sh invokes it:
#     SL_SKILLS_DIR set, no arguments) must also see the agent-authored
#     skill through .usage.json -- proving the C4 fix closes the lifecycle
#     blindness too, not just the AGENTS.md listing.
LIFECYCLE_OUT="$(env -i HOME="$TMP_HOME" PATH="$PATH" SL_SKILLS_DIR="$SKILLS_DIR" \
    python3 "${SCRIPT_DIR}/scripts/skill-lifecycle.py" --dry-run 2>&1)"
not_contains "skill-lifecycle.py does not report 'Nothing to do' once a real skill exists" \
    "$LIFECYCLE_OUT" "Nothing to do"
check "skill-lifecycle.py's dry-run checked exactly 1 skill" "yes" \
    "$(echo "$LIFECYCLE_OUT" | grep -q 'checked=1' && echo yes || echo no)"

# --- Step 5 (I8): a proposal whose skill name follows the dot-inclusive
#     charset the reviewer prompts used to state (contradicting the actual
#     schema) must be rejected wholesale -- and, critically, that rejection
#     must leave a trace in persist-failures.log rather than vanishing
#     silently, since a single bad skill name would otherwise discard good
#     memory entries with no record anywhere.
TMP_HOME2="$(mktemp -d)"
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
```json
{"version": 1,
 "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "should-not-survive-bad-skill-name"}],
 "skills": [{"name": "git.rebase", "content": "x"}]}
```
JSON
FAKE
chmod +x "${FAKE_BIN}/copilot"

env -i HOME="$TMP_HOME2" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME2}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

# See the widened-timeout rationale above.
_sl_e2e_logged=0
for _ in $(seq 1 150); do
    if [[ -f "${TMP_HOME2}/store/logs/persist-failures.log" ]]; then
        _sl_e2e_logged=1
        break
    fi
    sleep 0.2
done
if [[ "$_sl_e2e_logged" -eq 0 ]]; then
    echo "--- timed out waiting for ${TMP_HOME2}/store/logs/persist-failures.log ---"
    find "${TMP_HOME2}/store" 2>&1 || echo "(store not even created)"
fi

check "dotted skill name: memory NOT persisted despite being valid" "no" \
    "$([[ -f "${TMP_HOME2}/store/memory/MEMORY.md" ]] && echo yes || echo no)"
check "dotted skill name: failure logged to persist-failures.log (not a silent no-op)" "yes" \
    "$([[ -s "${TMP_HOME2}/store/logs/persist-failures.log" ]] && echo yes || echo no)"
rm -rf "$TMP_HOME2"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All e2e skill-visibility tests passed."
