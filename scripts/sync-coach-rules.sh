#!/usr/bin/env bash
# scripts/sync-coach-rules.sh
# Vendor the MIT-licensed anti-pattern rule files from microsoft/AI-Engineering-Coach.
# Requires: gh (authenticated), jq.

set -euo pipefail

REPO="microsoft/AI-Engineering-Coach"
RULES_PATH="src/core/rules"
# The two lookup tables four rules need are plain literals in this file. They
# are vendored the same way the rules are, and pinned the same way -- see
# scripts/lib/coachtables.py for why a table is not a special case.
INTERPRETER_PATH="src/core/dsl/interpreter.ts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${SCRIPT_DIR}/vendor/coach-rules"

# A maintainer script, but it still may not hardcode `python3`: the one
# resolver decides which interpreter exists (see scripts/lib/python-resolve.sh).
# shellcheck source=scripts/lib/python-resolve.sh
source "${SCRIPT_DIR}/scripts/lib/python-resolve.sh"
sl_resolve_python || exit 1

mkdir -p "$DEST"

COMMIT_SHA=$(gh api "repos/${REPO}/commits/HEAD" --jq '.sha')

COUNT=0
for FILE in $(gh api "repos/${REPO}/contents/${RULES_PATH}?ref=${COMMIT_SHA}" --jq '.[] | select(.name | endswith(".md")) | .name'); do
    # The name comes from a remote API and is interpolated into a write path.
    # A slash or a .. in it would write outside vendor/coach-rules.
    case "$FILE" in
        */*|*..*) echo "refusing suspicious upstream filename: $FILE" >&2; exit 1 ;;
    esac
    gh api "repos/${REPO}/contents/${RULES_PATH}/${FILE}?ref=${COMMIT_SHA}" --jq '.content' \
        | "${SL_PYTHON}" -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "${DEST}/${FILE}"
    COUNT=$((COUNT + 1))
    echo "  vendored: ${FILE}"
done

# Lookup tables. Extraction fails loudly on a missing anchor rather than
# writing an empty table: an empty MODEL_TIERS would make modelTier() return 0
# for every model and silently switch off three rules.
TMP_TS="$(mktemp)"
TMP_LEO=""
cleanup() {
    rm -f "${TMP_TS}" 2>/dev/null || true
    [[ -n "${TMP_LEO}" ]] && rm -rf "${TMP_LEO}" 2>/dev/null || true
}
trap cleanup EXIT

gh api "repos/${REPO}/contents/${INTERPRETER_PATH}?ref=${COMMIT_SHA}" --jq '.content' \
    | "${SL_PYTHON}" -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "${TMP_TS}"
"${SL_PYTHON}" "${SCRIPT_DIR}/scripts/lib/coachtables.py" extract "${TMP_TS}" "${DEST}/tables"
# Profanity dictionary. Upstream deliberately keeps the plaintext wordlist out
# of its repository and depends on leo-profanity instead; this project keeps
# that property by committing SHA-256 hashes, which behave identically because
# leoProfanity.check() is exact whole-word set membership.
LEO_VERSION="$("${SL_PYTHON}" -c 'import sys;sys.path.insert(0,"'"${SCRIPT_DIR}"'/scripts/lib");import coachtables;print(coachtables.PROFANITY_VERSION)')"
TMP_LEO="$(mktemp -d)"
curl -fsSL "https://registry.npmjs.org/leo-profanity/-/leo-profanity-${LEO_VERSION}.tgz" \
    -o "${TMP_LEO}/leo.tgz"
tar xzf "${TMP_LEO}/leo.tgz" -C "${TMP_LEO}"
"${SL_PYTHON}" "${SCRIPT_DIR}/scripts/lib/coachtables.py" hash-dictionary \
    "${TMP_LEO}/package/dictionary/default.json" "${DEST}/tables"

echo "  (if a sha256 above differs from scripts/lib/coachtables.py TABLE_PINS,"
echo "   re-read the adapters that consume it BEFORE updating the pin)"

# Rule text is pinned the same way the tables are, and updated the same way:
# printed for a human to paste, never self-rewritten. The pin is the
# acknowledgement that the prose reaching the review prompt changed.
echo ""
echo "  RULES_MANIFEST for scripts/lib/coachtables.py (replace the block verbatim"
echo "  after reading the diff of the rule files above):"
"${SL_PYTHON}" "${SCRIPT_DIR}/scripts/lib/coachtables.py" hash-rules "$DEST"

cat > "${DEST}/UPSTREAM.md" <<EOF
# Vendored from ${REPO} (MIT License)
- Path: ${RULES_PATH}
- Commit: ${COMMIT_SHA}
- Synced: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Files: ${COUNT} rule files, plus tables/ extracted from ${INTERPRETER_PATH}
- Re-sync: bash scripts/sync-coach-rules.sh
EOF

echo "Vendored ${COUNT} rule files at commit ${COMMIT_SHA:0:12}"
