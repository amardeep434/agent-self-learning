### Task 8: Test runner and 3-OS CI

**Files:**
- Create: `tests/run-all.sh`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: every `tests/test-*.sh` and `tests/test-*.py`.
- Produces: `bash tests/run-all.sh` — exit 0 only if every test passes.

**Context:** this repository has **no CI and no test runner today**; tests are run by hand. Multi-platform support is a stated requirement, so the matrix is part of the deliverable, not a follow-up.

- [ ] **Step 1: Write the runner**

```bash
#!/usr/bin/env bash
# tests/run-all.sh — run every test, report a summary, fail loudly.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
FAILED=()

for t in tests/test-*.sh; do
    [[ "$(basename "$t")" == "run-all.sh" ]] && continue
    echo "=== $t ==="
    bash "$t" || FAILED+=("$t")
done

for t in tests/test-*.py; do
    echo "=== $t ==="
    python3 "$t" || FAILED+=("$t")
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "All tests passed."
```

- [ ] **Step 2: Run it to see the current state**

Run: `bash tests/run-all.sh`
Expected: PASS for everything implemented so far. Any failure here is real and must be fixed before proceeding.

- [ ] **Step 3: Write the CI workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        python-version: ["3.9", "3.13"]
    runs-on: ${{ matrix.os }}
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - name: Install jq (macOS)
        if: runner.os == 'macOS'
        run: brew install jq
      - name: Run tests
        run: bash tests/run-all.sh
```

Note: `shell: bash` makes the Windows runner use Git Bash, which is the same environment the Windows hook path delegates to — so the matrix tests what actually ships. `jq` is preinstalled on the Ubuntu and Windows runners.

- [ ] **Step 4: Verify locally, then push and confirm all six jobs pass**

Run: `bash tests/run-all.sh`
Expected: `All tests passed.` Then push the branch and confirm the six matrix jobs are green before merging.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/run-all.sh
git add tests/run-all.sh .github/workflows/ci.yml
git commit -m "ci: test runner and 3-OS x 2-Python matrix"
```

---

