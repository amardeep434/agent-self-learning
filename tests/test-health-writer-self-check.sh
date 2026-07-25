#!/usr/bin/env bash
# tests/test-health-writer-self-check.sh
#
# C3: self-learning-health.sh's REQUIRED_SCRIPTS list omitted
# persist-proposal.py, lib/proposal_schema.py, copilot-session-review.sh,
# and doctor.sh. A reviewer that copied a good install and then deleted
# persist-proposal.py and lib/proposal_schema.py (the writer and its own
# import) still printed "Status: HEALTHY" -- the exact defect class this
# project exists to eliminate, invisible to the one command install.sh
# tells users to run.
#
# A file-existence check alone is also insufficient: it cannot catch
# lib/proposal_schema.py being present but CORRUPT/unimportable. This suite
# proves both: (1) REQUIRED_SCRIPTS now names all four files, and (2) health
# actually EXERCISES persist-proposal.py end-to-end (via its existing
# --dry-run mode) against a canned proposal in an isolated temp store, so a
# broken import fails loudly instead of merely "the file is present".
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
contains() { case "$2" in *"$3"*) echo "PASS: $1";; *) echo "FAIL: $1 (output did not contain '$3')"; FAILURES=$((FAILURES+1));; esac; }

# Build a full, healthy, standalone copy of the scripts dir (mirrors a real
# install.sh output) under a temp store, so we control exactly what is
# present/absent without touching a real install.
build_store_scripts() {
    local dest="$1"
    mkdir -p "${dest}/lib"
    cp "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/scripts/*.py "$dest/" 2>/dev/null
    chmod +x "${dest}"/*.sh
    cp "${SCRIPT_DIR}"/scripts/lib/*.sh "${SCRIPT_DIR}"/scripts/lib/*.py "${dest}/lib/" 2>/dev/null
}

run_health() {
    local tmp_home="$1" store="$2"
    env -i HOME="$tmp_home" PATH="$PATH" AGENT_LEARNING_HOME="$store" \
        SL_CONFIG_FILE="/nonexistent/x.conf" \
        bash "${store}/scripts/self-learning-health.sh" 2>&1
}

seed_dirs() {
    local store="$1"
    mkdir -p "${store}/state" "${store}/learned-skills" "${store}/sessions" \
             "${store}/logs/reviews" "${store}/logs/curator"
}

## ============================================================
## 1. A healthy, complete install must still report HEALTHY (no false
##    positive introduced by this fix).
## ============================================================
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
build_store_scripts "${STORE}/scripts"
seed_dirs "$STORE"
OUT="$(run_health "$TMP_HOME" "$STORE")"
STATUS=$?
check "complete install: health exits 0" "0" "$STATUS"
contains "complete install: reports HEALTHY" "$OUT" "Status: HEALTHY"
contains "complete install: persist-proposal.py listed as a required script" "$OUT" "persist-proposal.py present"
contains "complete install: lib/proposal_schema.py listed as a required script" "$OUT" "lib/proposal_schema.py present"
contains "complete install: copilot-session-review.sh listed as a required script" "$OUT" "copilot-session-review.sh present"
contains "complete install: doctor.sh listed as a required script" "$OUT" "doctor.sh present"
contains "complete install: writer self-check exercised persist-proposal.py and passed" "$OUT" "writer self-check"
rm -rf "$TMP_HOME"

## ============================================================
## 2. C3's exact repro: persist-proposal.py and lib/proposal_schema.py
##    deleted. Must NOT report HEALTHY.
## ============================================================
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
build_store_scripts "${STORE}/scripts"
seed_dirs "$STORE"
rm -f "${STORE}/scripts/persist-proposal.py" "${STORE}/scripts/lib/proposal_schema.py"
OUT="$(run_health "$TMP_HOME" "$STORE")"
STATUS=$?
check "C3 repro: health with writer deleted exits non-zero" "1" "$STATUS"
case "$OUT" in
    *"Status: HEALTHY"*) echo "FAIL: C3 repro still reports HEALTHY with the writer deleted"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: C3 repro does not report HEALTHY" ;;
esac
contains "C3 repro: persist-proposal.py reported missing" "$OUT" "persist-proposal.py missing"
contains "C3 repro: lib/proposal_schema.py reported missing" "$OUT" "lib/proposal_schema.py missing"
rm -rf "$TMP_HOME"

## ============================================================
## 3. Mutation test the self-check itself: files present but CORRUPT
##    (proposal_schema.py fails to import). File-existence checks alone
##    would pass here -- only actually exercising the writer catches it.
## ============================================================
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
build_store_scripts "${STORE}/scripts"
seed_dirs "$STORE"
printf 'this is not valid python at all !!! %%%%\n' > "${STORE}/scripts/lib/proposal_schema.py"
OUT="$(run_health "$TMP_HOME" "$STORE")"
STATUS=$?
check "corrupt proposal_schema.py: health exits non-zero" "1" "$STATUS"
case "$OUT" in
    *"Status: HEALTHY"*) echo "FAIL: health reports HEALTHY despite a corrupt, unimportable proposal_schema.py"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: health does not report HEALTHY with a corrupt proposal_schema.py" ;;
esac
contains "corrupt proposal_schema.py: writer self-check fails" "$OUT" "writer self-check"
rm -rf "$TMP_HOME"

## ============================================================
## 4. The self-check must never write into the real store: prove that
##    calling it does not create anything under the real memory/skills dirs
##    outside of a controlled temp location.
## ============================================================
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
build_store_scripts "${STORE}/scripts"
seed_dirs "$STORE"
run_health "$TMP_HOME" "$STORE" >/dev/null 2>&1
check "self-check never wrote into the real memory dir" "no" \
    "$([[ -e "${STORE}/memory/MEMORY.md" ]] && echo yes || echo no)"
rm -rf "$TMP_HOME"

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "All health writer self-check tests passed."
