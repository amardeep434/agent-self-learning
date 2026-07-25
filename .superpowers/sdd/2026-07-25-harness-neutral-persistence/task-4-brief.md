### Task 4: Secure writer

**Files:**
- Create: `scripts/persist-proposal.py`
- Test: `tests/test-persist-proposal.py`

**Interfaces:**
- Consumes: `scripts/lib/paths.py` (`resolve_all`), `scripts/lib/proposal_schema.py` (`extract_proposal`, `validate_proposal`, `ValidationError`).
- Produces: CLI `python3 scripts/persist-proposal.py [--dry-run]` reading reviewer stdout on stdin. Exit `0` = wrote (or nothing to write), `1` = invalid proposal, `2` = write failure. Prints a one-line JSON summary to stdout: `{"written": [...], "skipped": [...], "bytes": N}`.

**Why exit codes matter:** the defect this plan fixes was *invisible* — hook exited 0, a log file existed, and nothing was persisted. A non-zero exit on failure is the difference between a bug you find in a minute and one you find in three months.

- [ ] **Step 1: Write the failing test**

```python
# tests/test-persist-proposal.py
import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "persist-proposal.py"


def run(stdin_text, home, extra_args=()):
    env = dict(os.environ, AGENT_LEARNING_HOME=str(home))
    return subprocess.run([sys.executable, str(WRITER), *extra_args],
                          input=stdin_text, capture_output=True, text=True, env=env)


class TestWrites(unittest.TestCase):
    def test_writes_memory_and_skill(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "remembered"}],
                                  "skills": [{"name": "alpha", "content": "# Alpha"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "remembered")
            self.assertEqual((home / "learned-skills" / "alpha.md").read_text(), "# Alpha")

    def test_append_mode_appends(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory").mkdir(parents=True)
            (home / "memory" / "MEMORY.md").write_text("first\n")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "second\n"}]})
            self.assertEqual(run(payload, home).returncode, 0)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "first\nsecond\n")

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home, extra_args=("--dry-run",))
            self.assertEqual(r.returncode, 0)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_no_json_is_success_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            r = run("the model just chatted at us", home)
            self.assertEqual(r.returncode, 0)
            self.assertFalse((home / "memory").exists())


class TestRejects(unittest.TestCase):
    def test_invalid_proposal_exits_1_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "../escape.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((Path(d).parent / "escape.md").exists())

    def test_partial_validity_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "ok"}],
                                  "skills": [{"name": "../evil", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_symlinked_target_is_refused(self):
        if sys.platform.startswith("win"):
            self.skipTest("symlink creation requires privilege on Windows")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("original")
            (home / "memory" / "MEMORY.md").symlink_to(outside)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "original")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test-persist-proposal.py`
Expected: FAIL — writer script does not exist (`can't open file .../persist-proposal.py`)

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""Persist a reviewer proposal. The ONLY component that writes memory/skills.

Reads reviewer stdout on stdin, extracts and validates the proposal, then
writes every file itself. The reviewer agent needs no write tool at all — which
is what makes this work identically on Claude Code, Copilot CLI, and VS Code
Copilot Chat, none of whose path allow-lists we can control.

Nothing is written unless the whole proposal validates: a partially applied
proposal is a corrupted store.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import paths  # noqa: E402
from proposal_schema import ValidationError, extract_proposal, validate_proposal  # noqa: E402


def _assert_inside(root: Path, target: Path) -> None:
    """Refuse anything that resolves outside the store, including via symlink.

    The schema already forbids traversal syntactically; this is the second,
    filesystem-level check. Defence in depth is warranted because the input
    ultimately originates from model output.
    """
    root_r = root.resolve()
    parent_r = target.parent.resolve()
    if root_r != parent_r and root_r not in parent_r.parents:
        raise PermissionError(f"refusing write outside store: {target}")
    if target.is_symlink():
        raise PermissionError(f"refusing write through symlink: {target}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Persist a reviewer proposal.")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate and report without writing")
    args = parser.parse_args(argv)

    raw = sys.stdin.read()
    obj = extract_proposal(raw)
    if obj is None:
        print(json.dumps({"written": [], "skipped": ["no-proposal"], "bytes": 0}))
        return 0

    try:
        proposal = validate_proposal(obj)
    except ValidationError as exc:
        print(f"persist-proposal: invalid proposal: {exc}", file=sys.stderr)
        return 1

    resolved = paths.resolve_all()
    memory_dir, skills_dir = resolved["memory"], resolved["skills"]

    # Each planned write carries its own root so confinement is checked against
    # the directory the entry actually belongs to. Inferring the root from the
    # target's name would be fragile and is exactly the kind of shortcut that
    # turns into a traversal bug.
    planned: list[tuple[Path, Path, str, str]] = []
    for entry in proposal["memory"]:
        planned.append((memory_dir, memory_dir / entry["file"], entry["mode"], entry["content"]))
    for entry in proposal["skills"]:
        planned.append((skills_dir, skills_dir / f"{entry['name']}.md", "replace", entry["content"]))

    if args.dry_run:
        print(json.dumps({"written": [], "skipped": [str(p) for _, p, _, _ in planned],
                          "bytes": sum(len(c.encode("utf-8")) for _, _, _, c in planned)}))
        return 0

    written: list[str] = []
    total = 0
    try:
        for root, target, mode, content in planned:
            target.parent.mkdir(parents=True, exist_ok=True)
            _assert_inside(root, target)
            with open(target, "a" if mode == "append" else "w", encoding="utf-8",
                      newline="\n") as handle:
                handle.write(content)
            written.append(str(target))
            total += len(content.encode("utf-8"))
    except (OSError, PermissionError) as exc:
        print(f"persist-proposal: write failed: {exc}", file=sys.stderr)
        return 2

    print(json.dumps({"written": written, "skipped": [], "bytes": total}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tests/test-persist-proposal.py`
Expected: PASS (7 tests; the symlink test skips on Windows)

- [ ] **Step 5: Commit**

```bash
git add scripts/persist-proposal.py tests/test-persist-proposal.py
git commit -m "feat(security): script-owned writer with store confinement and explicit exit codes"
```

---

