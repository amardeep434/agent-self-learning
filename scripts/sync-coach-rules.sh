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

mkdir -p "$DEST"

COMMIT_SHA=$(gh api "repos/${REPO}/commits/HEAD" --jq '.sha')

COUNT=0
for FILE in $(gh api "repos/${REPO}/contents/${RULES_PATH}?ref=${COMMIT_SHA}" --jq '.[] | select(.name | endswith(".md")) | .name'); do
    gh api "repos/${REPO}/contents/${RULES_PATH}/${FILE}?ref=${COMMIT_SHA}" --jq '.content' \
        | python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "${DEST}/${FILE}"
    COUNT=$((COUNT + 1))
    echo "  vendored: ${FILE}"
done

# Lookup tables. Extraction fails loudly on a missing anchor rather than
# writing an empty table: an empty MODEL_TIERS would make modelTier() return 0
# for every model and silently switch off three rules.
TMP_TS="$(mktemp)"
trap 'rm -f "${TMP_TS}"' EXIT
gh api "repos/${REPO}/contents/${INTERPRETER_PATH}?ref=${COMMIT_SHA}" --jq '.content' \
    | python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "${TMP_TS}"
python3 "${SCRIPT_DIR}/scripts/lib/coachtables.py" extract "${TMP_TS}" "${DEST}/tables"
echo "  (if a sha256 above differs from scripts/lib/coachtables.py TABLE_PINS,"
echo "   re-read the adapters that consume it BEFORE updating the pin)"

cat > "${DEST}/UPSTREAM.md" <<EOF
# Vendored from ${REPO} (MIT License)
- Path: ${RULES_PATH}
- Commit: ${COMMIT_SHA}
- Synced: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Files: ${COUNT} rule files, plus tables/ extracted from ${INTERPRETER_PATH}
- Re-sync: bash scripts/sync-coach-rules.sh
EOF

echo "Vendored ${COUNT} rule files at commit ${COMMIT_SHA:0:12}"
