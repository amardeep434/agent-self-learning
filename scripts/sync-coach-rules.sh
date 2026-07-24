#!/usr/bin/env bash
# scripts/sync-coach-rules.sh
# Vendor the MIT-licensed anti-pattern rule files from microsoft/AI-Engineering-Coach.
# Requires: gh (authenticated), jq.

set -euo pipefail

REPO="microsoft/AI-Engineering-Coach"
RULES_PATH="src/core/rules"
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

cat > "${DEST}/UPSTREAM.md" <<EOF
# Vendored from ${REPO} (MIT License)
- Path: ${RULES_PATH}
- Commit: ${COMMIT_SHA}
- Synced: $(date -Iseconds)
- Files: ${COUNT}
- Re-sync: bash scripts/sync-coach-rules.sh
EOF

echo "Vendored ${COUNT} rule files at commit ${COMMIT_SHA:0:12}"
