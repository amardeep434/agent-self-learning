# Harness-Neutral Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the learning loop actually persist on every harness — with a vendor-neutral store, a script-owned write path that no agent can abuse, and a test that proves it works with Claude Code absent.

**Architecture:** Today the spawned reviewer agent writes `MEMORY.md` / `learned-skills/` itself, into `~/.claude/...`. On GitHub Copilot CLI that write is refused by Copilot's path allowlist, so the loop completes and silently persists **nothing** (evidenced in `~/.claude/logs/reviews/20260723-125206-copilot-session-review.log`). We invert the contract: the reviewer **emits a JSON proposal on stdout and writes no files**; a deterministic Python writer validates that proposal against a strict schema and performs every write itself, confined to a platform-neutral store root. This removes the path-allowlist dependency, collapses two divergent write paths into one, makes the write path unit-testable without a live agent, and removes agent-filesystem trust from the design.

**Tech Stack:** bash (hook entry scripts), Python 3.9+ stdlib only, `jq` (already a runtime dependency), GitHub Actions.

## Global Constraints

- Python: **standard library only**. No new pip dependencies in this plan.
- Bash: must run under `bash` on Linux, macOS, and Windows Git Bash. No GNU-only flags (`sed -i` without suffix, `readlink -f`, `stat -c` are forbidden — use portable equivalents).
- **No code path used by Copilot CLI or VS Code may reference `~/.claude`, the `claude` binary, or `CLAUDE.md`.** Claude Code is one adapter among peers, never a dependency.
- Paths are computed in **exactly one place** (`scripts/lib/paths.py`). Bash obtains paths by calling it. Never reimplement resolution in bash.
- The reviewer agent **must not be granted file-write tools** for persistence purposes. All persistence is done by `scripts/persist-proposal.py`.
- Existing test style is authoritative: standalone executable scripts in `tests/`, `check()` helper, `FAILURES` counter, `env -i` isolation, `exit 1` on failure.
- Backward compatibility: existing installs whose store is `~/.claude` must keep working and must be told how to migrate. Never silently relocate a user's data.
- Every task ends with a commit. Conventional-commit prefixes (`feat:`, `fix:`, `test:`, `ci:`, `docs:`).

---

## File Structure

**Create:**
- `scripts/lib/paths.py` — single source of truth for every framework path. Platform-aware resolution + override chain. Importable and CLI-callable.
- `scripts/lib/proposal_schema.py` — the proposal contract: schema constants, `validate_proposal()`, size/count caps.
- `scripts/persist-proposal.py` — reads a proposal on stdin, validates, writes files under the store root. The only component that writes memory/skills.
- `scripts/doctor.sh` — prints resolved paths, writability, harness detection, legacy-store detection.
- `tests/test-paths.py` — path resolution unit tests.
- `tests/test-proposal-schema.py` — schema validation unit tests, including hostile inputs.
- `tests/test-persist-proposal.py` — writer tests, including path-traversal and symlink attacks.
- `tests/test-claude-absent.sh` — the regression guard: Copilot path persists with no `claude` binary and no `~/.claude`.
- `tests/run-all.sh` — test runner (none exists today).
- `.github/workflows/ci.yml` — 3-OS × 2-Python matrix (none exists today).

**Modify:**
- `scripts/lib/config.sh` — delegate path defaults to `paths.py`; drop the hardcoded `${HOME}/.claude` defaults; add `SL_REVIEW_ENABLED` with `CLAUDE_REVIEW_ENABLED` back-compat.
- `scripts/session-review.sh` — prompt instructs stdout-only proposal; pipe reviewer stdout into `persist-proposal.py`.
- `scripts/copilot-session-review.sh` — same inversion; drop `--allow-tool write`.
- `config/settings-hooks.json` — remove the 8 dead `CLAUDE_REVIEW_*` env entries, keep behavior via `SL_*`.

**Unchanged but load-bearing:** `scripts/lib/hook-input.sh` (Claude-shaped payload parsing; the Copilot branch is a later plan), `scripts/coach-signals.py`.

---

### Task 1: Path resolver

**Files:**
- Create: `scripts/lib/paths.py`
- Test: `tests/test-paths.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `resolve_home() -> pathlib.Path`, `resolve_all() -> dict[str, pathlib.Path]` with keys exactly `home, state, skills, memory, logs, sessions_db, config_file`, `legacy_home() -> pathlib.Path | None`. CLI: `python3 scripts/lib/paths.py get <key>` prints one path; `python3 scripts/lib/paths.py all` prints `KEY=value` lines.

- [ ] **Step 1: Write the failing test**

```python
# tests/test-paths.py
import os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import paths  # noqa: E402


class TestResolveHome(unittest.TestCase):
    def _env(self, **kw):
        base = {k: v for k, v in os.environ.items() if not k.startswith(
            ("AGENT_LEARNING_", "XDG_DATA_HOME", "LOCALAPPDATA", "SL_"))}
        base.update(kw)
        return base

    def test_explicit_override_wins(self):
        env = self._env(AGENT_LEARNING_HOME="/tmp/explicit", XDG_DATA_HOME="/tmp/xdg")
        self.assertEqual(paths.resolve_home(env, platform="linux"), Path("/tmp/explicit"))

    def test_xdg_used_when_set(self):
        env = self._env(XDG_DATA_HOME="/tmp/xdg", HOME="/home/u")
        self.assertEqual(paths.resolve_home(env, platform="linux"),
                         Path("/tmp/xdg/agent-learning"))

    def test_linux_default(self):
        env = self._env(HOME="/home/u")
        self.assertEqual(paths.resolve_home(env, platform="linux"),
                         Path("/home/u/.local/share/agent-learning"))

    def test_windows_uses_localappdata(self):
        env = self._env(LOCALAPPDATA="C:\\Users\\u\\AppData\\Local", HOME="C:\\Users\\u")
        self.assertEqual(paths.resolve_home(env, platform="win32"),
                         Path("C:\\Users\\u\\AppData\\Local") / "agent-learning")

    def test_no_claude_in_any_default(self):
        env = self._env(HOME="/home/u")
        for p in paths.resolve_all(env, platform="linux").values():
            self.assertNotIn(".claude", str(p))

    def test_all_keys_present(self):
        env = self._env(HOME="/home/u")
        self.assertEqual(
            set(paths.resolve_all(env, platform="linux")),
            {"home", "state", "skills", "memory", "logs", "sessions_db", "config_file"})


class TestLegacyDetection(unittest.TestCase):
    def test_legacy_reported_when_present(self):
        with tempfile.TemporaryDirectory() as d:
            legacy = Path(d) / ".claude" / "memory"
            legacy.mkdir(parents=True)
            env = {"HOME": d}
            self.assertEqual(paths.legacy_home(env), Path(d) / ".claude")

    def test_legacy_none_when_absent(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(paths.legacy_home({"HOME": d}))


class TestCli(unittest.TestCase):
    def test_get_prints_single_path(self):
        env = dict(os.environ, AGENT_LEARNING_HOME="/tmp/x")
        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "memory"],
            capture_output=True, text=True, env=env, check=True).stdout.strip()
        self.assertEqual(out, str(Path("/tmp/x/memory")))

    def test_get_unknown_key_exits_nonzero(self):
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "nope"],
            capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test-paths.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'paths'`

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""Single source of truth for every agent-self-learning path.

Resolution order (first hit wins):
  1. $AGENT_LEARNING_HOME    explicit override — makes testing and debugging trivial
  2. $XDG_DATA_HOME/agent-learning
  3. Windows: %LOCALAPPDATA%\\agent-learning
  4. ~/.local/share/agent-learning        (Linux and macOS)

The store name is vendor-neutral on purpose: this framework serves Claude Code,
GitHub Copilot CLI, and VS Code Copilot Chat as peers. No default may point
inside ~/.claude — Copilot's path allowlist refuses writes to foreign
namespaces, which is what silently broke persistence before this module existed.

Bash callers MUST shell out to this file rather than recomputing paths, so the
two languages can never disagree across three operating systems.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

APP_DIR_NAME = "agent-learning"

_SUBPATHS = {
    "state": ("state",),
    "skills": ("learned-skills",),
    "memory": ("memory",),
    "logs": ("logs",),
    "sessions_db": ("sessions", "search.db"),
    "config_file": ("self-learning.conf",),
}


def resolve_home(env: dict | None = None, platform: str | None = None) -> Path:
    env = os.environ if env is None else env
    platform = sys.platform if platform is None else platform

    explicit = env.get("AGENT_LEARNING_HOME")
    if explicit:
        return Path(explicit)

    xdg = env.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / APP_DIR_NAME

    if platform.startswith("win"):
        local = env.get("LOCALAPPDATA")
        if local:
            return Path(local) / APP_DIR_NAME

    return Path(env.get("HOME", "")) / ".local" / "share" / APP_DIR_NAME


def resolve_all(env: dict | None = None, platform: str | None = None) -> dict[str, Path]:
    home = resolve_home(env, platform)
    out = {"home": home}
    for key, parts in _SUBPATHS.items():
        out[key] = home.joinpath(*parts)
    return out


def legacy_home(env: dict | None = None) -> Path | None:
    """Return the pre-neutral ~/.claude store if it looks populated.

    Detection only — this module never moves user data. `doctor` surfaces it
    and tells the user how to migrate deliberately.
    """
    env = os.environ if env is None else env
    home = env.get("HOME")
    if not home:
        return None
    candidate = Path(home) / ".claude"
    if (candidate / "memory").is_dir() or (candidate / "learned-skills").is_dir():
        return candidate
    return None


def _main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "get":
        resolved = resolve_all()
        key = argv[1]
        if key not in resolved:
            print(f"unknown path key: {key}", file=sys.stderr)
            return 2
        print(resolved[key])
        return 0
    if argv and argv[0] == "all":
        for key, value in resolve_all().items():
            print(f"{key}={value}")
        return 0
    print("usage: paths.py get <key> | paths.py all", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tests/test-paths.py`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/paths.py tests/test-paths.py
git commit -m "feat(paths): platform-aware vendor-neutral path resolver"
```

---

### Task 2: config.sh delegates to the resolver; env-var cleanup

**Files:**
- Modify: `scripts/lib/config.sh`
- Modify: `config/settings-hooks.json`
- Test: `tests/test-config.sh`

**Interfaces:**
- Consumes: `scripts/lib/paths.py` CLI (`all`).
- Produces: unchanged exported names `SL_HOME SL_STATE_DIR SL_SKILLS_DIR SL_MEMORY_DIR SL_LOG_DIR SL_SEARCH_DB`, plus new `SL_REVIEW_ENABLED`. Every other `SL_*` in the current file keeps its meaning.

**Context the implementer needs:** `scripts/session-review.sh` currently reads `CLAUDE_REVIEW_ENABLED` — it is the **only** live `CLAUDE_*` variable. `config/settings-hooks.json` sets nine `CLAUDE_REVIEW_*` entries; the other eight are read nowhere and are dead weight that implies Claude-coupling. Keep honoring `CLAUDE_REVIEW_ENABLED` for one release so existing installs do not silently change behavior.

- [ ] **Step 1: Write the failing test (append to existing file)**

```bash
# append to tests/test-config.sh, before the final FAILURES check

# Neutral defaults: no ~/.claude anywhere
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
case "$OUT" in
    *.claude*) echo "FAIL: SL_HOME still points into .claude ($OUT)"; FAILURES=$((FAILURES+1)) ;;
    *agent-learning*) echo "PASS: SL_HOME is vendor-neutral" ;;
    *) echo "FAIL: unexpected SL_HOME ($OUT)"; FAILURES=$((FAILURES+1)) ;;
esac

# Explicit override wins over platform default
OUT=$(env -i HOME="$HOME" PATH="$PATH" AGENT_LEARNING_HOME="/tmp/al" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_MEMORY_DIR\"")
check "AGENT_LEARNING_HOME drives SL_MEMORY_DIR" "/tmp/al/memory" "$OUT"

# New review flag defaults on
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED defaults true" "true" "$OUT"

# Legacy variable still honored for one release
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "legacy CLAUDE_REVIEW_ENABLED honored" "false" "$OUT"

# New variable beats legacy when both set
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_REVIEW_ENABLED=true SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED beats legacy" "true" "$OUT"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-config.sh`
Expected: FAIL — `SL_HOME still points into .claude (/home/<user>/.claude)` and `SL_REVIEW_ENABLED` empty.

- [ ] **Step 3: Modify `scripts/lib/config.sh`**

Add `SL_REVIEW_ENABLED` to the snapshot loop variable list (so pre-set env still wins), then replace the hardcoded default block:

```bash
# Replace these lines:
#   SL_HOME="${SL_HOME:-${HOME}/.claude}"
#   SL_STATE_DIR="${SL_STATE_DIR:-${SL_HOME}/state/self-learning}"
#   SL_SKILLS_DIR="${SL_SKILLS_DIR:-${SL_HOME}/learned-skills}"
#   SL_MEMORY_DIR="${SL_MEMORY_DIR:-${SL_HOME}/memory}"
#   SL_LOG_DIR="${SL_LOG_DIR:-${SL_HOME}/logs}"
#   SL_SEARCH_DB="${SL_SEARCH_DB:-${SL_HOME}/sessions/search.db}"
# with:

# Paths come from scripts/lib/paths.py — the single resolver shared with Python.
# Never recompute them here; bash and python disagreeing across three operating
# systems is exactly the drift this indirection prevents.
_sl_paths_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.py"
if [[ -f "$_sl_paths_py" ]]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            home)        SL_HOME="${SL_HOME:-$_v}" ;;
            state)       SL_STATE_DIR="${SL_STATE_DIR:-$_v}" ;;
            skills)      SL_SKILLS_DIR="${SL_SKILLS_DIR:-$_v}" ;;
            memory)      SL_MEMORY_DIR="${SL_MEMORY_DIR:-$_v}" ;;
            logs)        SL_LOG_DIR="${SL_LOG_DIR:-$_v}" ;;
            sessions_db) SL_SEARCH_DB="${SL_SEARCH_DB:-$_v}" ;;
        esac
    done < <(python3 "$_sl_paths_py" all 2>/dev/null)
fi
```

Then add the review flag with legacy fallback, after the other defaults:

```bash
# SL_REVIEW_ENABLED supersedes CLAUDE_REVIEW_ENABLED. The legacy name is
# honored for one release so existing installs do not change behavior on
# upgrade; it is Claude-branded and read on the Copilot path, which is
# precisely the vendor coupling this release removes.
if [[ -z "${SL_REVIEW_ENABLED:-}" && -n "${CLAUDE_REVIEW_ENABLED:-}" ]]; then
    SL_REVIEW_ENABLED="$CLAUDE_REVIEW_ENABLED"
    echo "agent-self-learning: CLAUDE_REVIEW_ENABLED is deprecated; use SL_REVIEW_ENABLED" >&2
fi
SL_REVIEW_ENABLED="${SL_REVIEW_ENABLED:-true}"
```

Add `SL_REVIEW_ENABLED` to the final `export` list.

In `config/settings-hooks.json`, replace the entire `"env"` object with:

```json
  "env": {
    "SL_MEMORY_REVIEW_INTERVAL": "10",
    "SL_SKILL_REVIEW_INTERVAL": "10",
    "SL_REVIEW_ENABLED": "true",
    "SL_REVIEW_MIN_TURNS": "5",
    "SL_REVIEW_MAX_TURNS": "16"
  },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-config.sh && python3 tests/test-paths.py`
Expected: PASS, including the pre-existing assertions.

Note: the pre-existing assertion `check "missing file falls back to defaults" "$HOME/.claude" "$OUT"` now contradicts the new default — update its expected value to `$HOME/.local/share/agent-learning`. This is a deliberate behavior change, not a broken test.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/config.sh config/settings-hooks.json tests/test-config.sh
git commit -m "feat(config): resolve paths via paths.py, add SL_REVIEW_ENABLED, drop dead CLAUDE_REVIEW_* entries"
```

---

### Task 3: Proposal schema and validator

**Files:**
- Create: `scripts/lib/proposal_schema.py`
- Test: `tests/test-proposal-schema.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `SCHEMA_VERSION: int`, `MAX_MEMORY_BYTES: int`, `MAX_SKILL_BYTES: int`, `MAX_SKILLS: int`, `MAX_TOTAL_BYTES: int`, `ALLOWED_MEMORY_FILES: frozenset[str]`, `ValidationError(Exception)`, `validate_proposal(obj: dict) -> dict`, `extract_proposal(text: str) -> dict`.

**Why this exists:** inverting to "script persists" removes the path-allowlist failure, but it creates a new surface — a prompt-injected session could propose hostile content that a naive writer would dutifully write. The schema is the security boundary, so it is strict by construction: fixed filenames for memory, `[A-Za-z0-9_-]` skill names, hard byte caps, and total rejection rather than partial acceptance.

- [ ] **Step 1: Write the failing test**

```python
# tests/test-proposal-schema.py
import sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import proposal_schema as ps  # noqa: E402


def good():
    return {"version": 1,
            "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "hello"}],
            "skills": [{"name": "my-skill", "content": "# Skill"}]}


class TestValid(unittest.TestCase):
    def test_accepts_minimal(self):
        self.assertEqual(ps.validate_proposal({"version": 1}),
                         {"version": 1, "memory": [], "skills": []})

    def test_accepts_full(self):
        self.assertEqual(ps.validate_proposal(good())["skills"][0]["name"], "my-skill")

    def test_extracts_from_fenced_block(self):
        text = 'chatter\n```json\n{"version": 1}\n```\ntrailing'
        self.assertEqual(ps.extract_proposal(text), {"version": 1})

    def test_extracts_bare_json(self):
        self.assertEqual(ps.extract_proposal('  {"version": 1}  '), {"version": 1})


class TestRejects(unittest.TestCase):
    def _bad(self, mutate):
        p = good(); mutate(p)
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_wrong_version(self):
        self._bad(lambda p: p.__setitem__("version", 2))

    def test_unknown_memory_file(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "OTHER.md", "mode": "replace", "content": "x"}))

    def test_path_traversal_in_memory_file(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "../../etc/passwd", "mode": "replace", "content": "x"}))

    def test_absolute_path_in_memory_file(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "/etc/passwd", "mode": "replace", "content": "x"}))

    def test_skill_name_with_slash(self):
        self._bad(lambda p: p["skills"].__setitem__(0, {"name": "a/b", "content": "x"}))

    def test_skill_name_with_dotdot(self):
        self._bad(lambda p: p["skills"].__setitem__(0, {"name": "..", "content": "x"}))

    def test_skill_name_empty(self):
        self._bad(lambda p: p["skills"].__setitem__(0, {"name": "", "content": "x"}))

    def test_bad_mode(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "MEMORY.md", "mode": "delete", "content": "x"}))

    def test_memory_too_large(self):
        self._bad(lambda p: p["memory"].__setitem__(
            0, {"file": "MEMORY.md", "mode": "replace", "content": "x" * (ps.MAX_MEMORY_BYTES + 1)}))

    def test_too_many_skills(self):
        self._bad(lambda p: p.__setitem__(
            "skills", [{"name": f"s{i}", "content": "x"} for i in range(ps.MAX_SKILLS + 1)]))

    def test_total_size_cap(self):
        chunk = "x" * (ps.MAX_SKILL_BYTES - 1)
        self._bad(lambda p: p.__setitem__(
            "skills", [{"name": f"s{i}", "content": chunk} for i in range(ps.MAX_SKILLS)]))

    def test_non_dict(self):
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal([1, 2, 3])

    def test_extract_returns_none_when_absent(self):
        self.assertIsNone(ps.extract_proposal("no json here at all"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test-proposal-schema.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'proposal_schema'`

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""The contract between the reviewer agent and the writer.

The reviewer agent emits one JSON object on stdout and writes no files. This
module is the security boundary for that object: everything is allow-listed,
size-capped, and rejected wholesale on any violation. A prompt-injected
session must not be able to steer a write outside the store, and a partially
valid proposal must never be partially applied.
"""
from __future__ import annotations

import json
import re

SCHEMA_VERSION = 1

MAX_MEMORY_BYTES = 64 * 1024
MAX_SKILL_BYTES = 32 * 1024
MAX_SKILLS = 10
MAX_TOTAL_BYTES = 256 * 1024

ALLOWED_MEMORY_FILES = frozenset({"MEMORY.md", "USER.md"})
ALLOWED_MODES = frozenset({"replace", "append"})
SKILL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


class ValidationError(Exception):
    pass


def _need(cond: bool, msg: str) -> None:
    if not cond:
        raise ValidationError(msg)


def _size(text: str) -> int:
    return len(text.encode("utf-8"))


def validate_proposal(obj: object) -> dict:
    _need(isinstance(obj, dict), "proposal must be a JSON object")
    assert isinstance(obj, dict)
    _need(obj.get("version") == SCHEMA_VERSION,
          f"version must be {SCHEMA_VERSION}, got {obj.get('version')!r}")

    memory_in = obj.get("memory", [])
    skills_in = obj.get("skills", [])
    _need(isinstance(memory_in, list), "memory must be a list")
    _need(isinstance(skills_in, list), "skills must be a list")
    _need(len(skills_in) <= MAX_SKILLS, f"at most {MAX_SKILLS} skills per proposal")

    total = 0
    memory_out = []
    for entry in memory_in:
        _need(isinstance(entry, dict), "memory entry must be an object")
        name = entry.get("file")
        mode = entry.get("mode", "replace")
        content = entry.get("content")
        # Exact-name allow-list: no join, no normalization, no traversal surface.
        _need(name in ALLOWED_MEMORY_FILES,
              f"memory file must be one of {sorted(ALLOWED_MEMORY_FILES)}, got {name!r}")
        _need(mode in ALLOWED_MODES, f"mode must be one of {sorted(ALLOWED_MODES)}")
        _need(isinstance(content, str), "memory content must be a string")
        _need(_size(content) <= MAX_MEMORY_BYTES,
              f"memory content exceeds {MAX_MEMORY_BYTES} bytes")
        total += _size(content)
        memory_out.append({"file": name, "mode": mode, "content": content})

    skills_out = []
    for entry in skills_in:
        _need(isinstance(entry, dict), "skill entry must be an object")
        name = entry.get("name")
        content = entry.get("content")
        _need(isinstance(name, str) and SKILL_NAME_RE.match(name),
              f"skill name must match {SKILL_NAME_RE.pattern}, got {name!r}")
        _need(isinstance(content, str), "skill content must be a string")
        _need(_size(content) <= MAX_SKILL_BYTES,
              f"skill content exceeds {MAX_SKILL_BYTES} bytes")
        total += _size(content)
        skills_out.append({"name": name, "content": content})

    _need(total <= MAX_TOTAL_BYTES, f"proposal exceeds {MAX_TOTAL_BYTES} bytes total")
    return {"version": SCHEMA_VERSION, "memory": memory_out, "skills": skills_out}


def extract_proposal(text: str) -> dict | None:
    """Pull the JSON object out of reviewer stdout.

    Agents wrap output in prose or fences no matter how firmly they are told
    not to, so accept a fenced block or a bare object. Returns None when no
    JSON object is present; callers treat that as 'nothing to persist', which
    is different from an invalid proposal (an error).
    """
    match = _FENCE_RE.search(text)
    candidate = match.group(1) if match else None
    if candidate is None:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end <= start:
            return None
        candidate = text[start:end + 1]
    try:
        return json.loads(candidate)
    except json.JSONDecodeError:
        return None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tests/test-proposal-schema.py`
Expected: PASS (18 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/proposal_schema.py tests/test-proposal-schema.py
git commit -m "feat(security): strict proposal schema with allow-lists and size caps"
```

---

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

### Task 5: Invert the Claude Code reviewer

**Files:**
- Modify: `scripts/session-review.sh` (prompt around line 58-66; spawn at line 113)
- Test: `tests/test-session-review.sh`

**Interfaces:**
- Consumes: `scripts/persist-proposal.py`, `SL_MEMORY_DIR`, `SL_SKILLS_DIR`, `SL_LOG_DIR`, `SL_REVIEW_ENABLED`.
- Produces: no new symbols. Behavioral contract: the reviewer's stdout is piped to the writer; the script exits non-zero if the writer fails.

- [ ] **Step 1: Write the failing test (append to `tests/test-session-review.sh`)**

```bash
# Reviewer output is persisted by the writer, not by the agent.
TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cat > "${FAKE_BIN}/claude" <<'FAKE'
#!/usr/bin/env bash
# Ignore all arguments; emit a valid proposal on stdout and write nothing.
cat <<'JSON'
```json
{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "persisted-by-writer"}]}
```
JSON
FAKE
chmod +x "${FAKE_BIN}/claude"

env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/session-review.sh" </dev/null >/dev/null 2>&1 || true

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "reviewer proposal persisted" "persisted-by-writer" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: MEMORY.md was not written by the writer"; FAILURES=$((FAILURES+1))
fi
rm -rf "$TMP_HOME" "$FAKE_BIN"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-session-review.sh`
Expected: FAIL — `MEMORY.md was not written by the writer` (the current script tells the agent to write, and the fake agent writes nothing).

- [ ] **Step 3: Modify `scripts/session-review.sh`**

Replace the write instruction in the prompt (currently line 66, `... Write to MEMORY.md or USER.md as appropriate.`) with an explicit stdout-only contract:

```bash
OUTPUT CONTRACT — follow exactly:
Do NOT write, create, or edit any file. You have no permission to do so and
any attempt will be discarded. Emit exactly one JSON object as your entire
final message, in a fenced json block:

```json
{"version": 1,
 "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "<full new contents>"}],
 "skills": [{"name": "kebab-case-name", "content": "<full skill markdown>"}]}
```

Rules: "file" must be MEMORY.md or USER.md. "mode" is "replace" or "append".
"name" must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}. Omit "memory" or "skills"
entirely when there is nothing to record. Emit nothing after the block.
```

Replace the spawn (currently line 113) so stdout flows into the writer:

```bash
# The reviewer proposes; this script persists. Piping through the writer is
# what makes the loop work on harnesses whose path allow-list refuses agent
# writes — and it keeps a single write implementation across all of them.
REVIEW_OUT="$(SL_REVIEW_ACTIVE=1 claude -p "$REVIEW_PROMPT" 2>>"${SL_LOG_DIR}/review-stderr.log")" || {
    echo "session-review: reviewer failed" >&2
    exit 1
}
printf '%s' "$REVIEW_OUT" | python3 "${SCRIPT_DIR}/persist-proposal.py" || {
    echo "session-review: persistence failed" >&2
    exit 1
}
```

Note for the implementer: the previous invocation was backgrounded with `nohup`. It must now be synchronous, because the script has to consume the reviewer's stdout. Keep the whole hook inside its configured timeout (`Stop` hook timeout is 15000 ms in `config/settings-hooks.json`); if the reviewer needs longer, raise that timeout in a follow-up rather than re-backgrounding, which would reintroduce the silent-failure mode.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-session-review.sh`
Expected: PASS, including pre-existing assertions.

- [ ] **Step 5: Commit**

```bash
git add scripts/session-review.sh tests/test-session-review.sh
git commit -m "fix(review): reviewer proposes on stdout, script persists (Claude Code path)"
```

---

### Task 6: Invert the Copilot reviewer

**Files:**
- Modify: `scripts/copilot-session-review.sh` (spawn at lines 75-76)
- Test: `tests/test-copilot-session-review.sh`

**Interfaces:**
- Consumes: `scripts/persist-proposal.py`, `SL_COPILOT_REVIEW_MODEL`, `SL_MEMORY_DIR`, `SL_SKILLS_DIR`.
- Produces: no new symbols. `--allow-tool write` is removed — the reviewer no longer needs it.

- [ ] **Step 1: Write the failing test (append to `tests/test-copilot-session-review.sh`)**

```bash
# Copilot reviewer output is persisted, and no write tool is requested.
TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "write" ]]; then
        echo "FAIL_MARKER: write tool was requested" >&2
        exit 3
    fi
done
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "copilot-persisted"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/copilot"

env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "copilot proposal persisted" "copilot-persisted" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: Copilot path did not persist"; FAILURES=$((FAILURES+1))
fi
rm -rf "$TMP_HOME" "$FAKE_BIN"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-copilot-session-review.sh`
Expected: FAIL — `Copilot path did not persist`, and the fake binary may print `FAIL_MARKER: write tool was requested`.

- [ ] **Step 3: Modify `scripts/copilot-session-review.sh`**

Replace the spawn block (lines 75-76 and its continuation) with:

```bash
# No --allow-tool write: the reviewer proposes, this script persists. Copilot
# CLI's path allow-list refused writes to the store, which made this loop a
# silent no-op; removing the write tool removes the dependency entirely.
COPILOT_ARGS=(-s --allow-tool read)
[[ -n "${SL_COPILOT_REVIEW_MODEL}" ]] && COPILOT_ARGS+=(--model "${SL_COPILOT_REVIEW_MODEL}")

REVIEW_OUT="$(SL_REVIEW_ACTIVE=1 copilot "${COPILOT_ARGS[@]}" -p "$REVIEW_PROMPT" \
    2>>"${SL_LOG_DIR}/copilot-review-stderr.log")" || {
    echo "copilot-session-review: reviewer failed" >&2
    exit 1
}
printf '%s' "$REVIEW_OUT" | python3 "${SCRIPT_DIR}/persist-proposal.py" || {
    echo "copilot-session-review: persistence failed" >&2
    exit 1
}
```

Replace this script's write instruction with the same stdout-only contract (repeated here in full so this task can be implemented without reading Task 5):

```bash
OUTPUT CONTRACT — follow exactly:
Do NOT write, create, or edit any file. You have no permission to do so and
any attempt will be discarded. Emit exactly one JSON object as your entire
final message, in a fenced json block:

```json
{"version": 1,
 "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "<full new contents>"}],
 "skills": [{"name": "kebab-case-name", "content": "<full skill markdown>"}]}
```

Rules: "file" must be MEMORY.md or USER.md. "mode" is "replace" or "append".
"name" must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}. Omit "memory" or "skills"
entirely when there is nothing to record. Emit nothing after the block.
```

The existing model-string regex validation must be kept exactly as-is — it guards `--model` against argument injection.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-copilot-session-review.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/copilot-session-review.sh tests/test-copilot-session-review.sh
git commit -m "fix(review): Copilot reviewer proposes on stdout; drop --allow-tool write"
```

---

### Task 7: Claude-absent regression guard

**Files:**
- Create: `tests/test-claude-absent.sh`

**Interfaces:**
- Consumes: `scripts/copilot-session-review.sh`, `scripts/persist-proposal.py`.
- Produces: no symbols. This is the executable form of the rule "no Copilot code path may depend on Claude Code."

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-claude-absent.sh
# The Copilot path must work on a machine with no `claude` binary and no
# ~/.claude directory. This is the regression guard for harness independence.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"

# A PATH containing copilot and the system basics, but deliberately no `claude`.
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "no-claude-needed"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/copilot"
MINIMAL_PATH="${FAKE_BIN}:/usr/bin:/bin"

if PATH="$MINIMAL_PATH" command -v claude >/dev/null 2>&1; then
    echo "FAIL: test setup is wrong — claude is reachable"; FAILURES=$((FAILURES+1))
else
    echo "PASS: claude is absent from PATH"
fi

env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "persisted without claude" "no-claude-needed" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: nothing persisted with claude absent"; FAILURES=$((FAILURES+1))
fi

# Nothing may have been created under ~/.claude.
if [[ -e "${TMP_HOME}/.claude" ]]; then
    echo "FAIL: Copilot path created ${TMP_HOME}/.claude"; FAILURES=$((FAILURES+1))
else
    echo "PASS: no ~/.claude created"
fi

# No shipped script referenced by the Copilot path may mention the claude binary.
if grep -nE '(^|[^a-z-])claude -p' "${SCRIPT_DIR}/scripts/copilot-session-review.sh" >/dev/null 2>&1; then
    echo "FAIL: copilot-session-review.sh invokes the claude binary"; FAILURES=$((FAILURES+1))
else
    echo "PASS: copilot path does not invoke claude"
fi

rm -rf "$TMP_HOME" "$FAKE_BIN"
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All claude-absent tests passed."
```

- [ ] **Step 2: Run test to verify it fails or passes for the right reason**

Run: `bash tests/test-claude-absent.sh`
Expected after Tasks 1-6: PASS. If it fails, the failure names the exact coupling still present — fix that, do not weaken the test.

- [ ] **Step 3: Make it executable and wire it into the runner (Task 8 creates the runner; if running out of order, just verify manually)**

```bash
chmod +x tests/test-claude-absent.sh
```

- [ ] **Step 4: Run once more to confirm**

Run: `bash tests/test-claude-absent.sh`
Expected: `All claude-absent tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tests/test-claude-absent.sh
git commit -m "test: guard that the Copilot path never depends on Claude Code"
```

---

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

### Task 9: `doctor` — make failures visible

**Files:**
- Create: `scripts/doctor.sh`
- Test: `tests/test-doctor.sh`

**Interfaces:**
- Consumes: `scripts/lib/config.sh`, `scripts/lib/paths.py`.
- Produces: `bash scripts/doctor.sh` — prints resolved paths, writability, detected harnesses, and legacy-store warning. Exit 0 when healthy, 1 when a required path is not writable.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-doctor.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1) || true

case "$OUT" in
    *"${TMP_HOME}/store/memory"*) echo "PASS: doctor prints resolved memory path" ;;
    *) echo "FAIL: memory path missing from doctor output"; FAILURES=$((FAILURES+1)) ;;
esac
case "$OUT" in
    *writable*) echo "PASS: doctor reports writability" ;;
    *) echo "FAIL: no writability report"; FAILURES=$((FAILURES+1)) ;;
esac

# Legacy store detection
mkdir -p "${TMP_HOME}/.claude/memory"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1) || true
case "$OUT" in
    *legacy*) echo "PASS: legacy store detected" ;;
    *) echo "FAIL: legacy store not reported"; FAILURES=$((FAILURES+1)) ;;
esac

rm -rf "$TMP_HOME"
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All doctor tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-doctor.sh`
Expected: FAIL — `scripts/doctor.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/doctor.sh — resolve and report framework state.
#
# The defect this framework shipped with was invisible: the hook exited 0, a
# log file existed, and nothing was persisted. `doctor` exists so that state is
# inspectable in seconds instead of months.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"

STATUS=0

echo "agent-self-learning doctor"
echo "--------------------------"
echo "resolved paths:"
for pair in "home:${SL_HOME}" "memory:${SL_MEMORY_DIR}" "skills:${SL_SKILLS_DIR}" \
            "state:${SL_STATE_DIR}" "logs:${SL_LOG_DIR}" "sessions_db:${SL_SEARCH_DB}"; do
    key="${pair%%:*}"; value="${pair#*:}"
    printf '  %-12s %s\n' "$key" "$value"
done

echo "writability:"
for dir in "${SL_MEMORY_DIR}" "${SL_SKILLS_DIR}" "${SL_STATE_DIR}" "${SL_LOG_DIR}"; do
    if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
        printf '  %-40s writable\n' "$dir"
    else
        printf '  %-40s NOT writable\n' "$dir"
        STATUS=1
    fi
done

echo "harnesses detected:"
command -v claude  >/dev/null 2>&1 && echo "  claude  (Claude Code)"  || echo "  claude  absent"
command -v copilot >/dev/null 2>&1 && echo "  copilot (Copilot CLI)"  || echo "  copilot absent"

if [[ -d "${HOME}/.claude/memory" || -d "${HOME}/.claude/learned-skills" ]]; then
    echo "legacy store found at ${HOME}/.claude"
    echo "  this release stores data at ${SL_HOME}"
    echo "  migrate deliberately, e.g.:"
    echo "    cp -r ${HOME}/.claude/memory ${HOME}/.claude/learned-skills ${SL_HOME}/"
fi

echo "review enabled: ${SL_REVIEW_ENABLED}"
exit "$STATUS"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-doctor.sh`
Expected: `All doctor tests passed.`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/doctor.sh
git add scripts/doctor.sh tests/test-doctor.sh
git commit -m "feat(doctor): report resolved paths, writability, harnesses, legacy store"
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none.

**Context:** `CLAUDE.md` currently describes Phase 1 as "Skeleton" and Phases 2-5 as "Planned" against 34 merged commits. Docs drift is a stated gate; this task closes the drift introduced before and by this plan.

- [ ] **Step 1: Update `README.md`**

Add a "Storage locations" section stating the resolution order (`AGENT_LEARNING_HOME` → `XDG_DATA_HOME/agent-learning` → `%LOCALAPPDATA%\agent-learning` → `~/.local/share/agent-learning`), a "Migrating from ~/.claude" note pointing at `scripts/doctor.sh`, and a note that `CLAUDE_REVIEW_ENABLED` is deprecated in favour of `SL_REVIEW_ENABLED`. Update the compatibility table so no row claims a harness is supported unless `tests/run-all.sh` covers it.

- [ ] **Step 2: Update `CLAUDE.md`**

Correct the roadmap table to reflect merged state, and add one line stating that Claude Code is one adapter among peers and that no shared code path may depend on it.

- [ ] **Step 3: Verify the claims**

Run: `bash tests/run-all.sh && bash scripts/doctor.sh`
Expected: all tests pass; doctor output matches the paths documented in the README.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: storage locations, migration, deprecation, corrected roadmap"
```

---

## Verification Gate (run before opening the PR)

- [ ] `bash tests/run-all.sh` passes locally
- [ ] `bash tests/test-claude-absent.sh` passes — the harness-independence guard
- [ ] All six CI matrix jobs green (3 OS × 2 Python)
- [ ] `bash scripts/doctor.sh` on a machine with an existing `~/.claude` store reports the legacy path and does not move anything
- [ ] `grep -rn 'claude' scripts/copilot-session-review.sh scripts/persist-proposal.py scripts/lib/paths.py` returns no binary invocation and no `~/.claude` path default
- [ ] Manual live check on Copilot CLI: run a real session, confirm a file appears under the resolved memory directory with real content — the specific failure this plan exists to fix

## Out of Scope (subsequent plans)

Session-source adapters (Copilot `session-store.db`, Claude JSONL) · VS Code hook spike and adapter · Copilot `postToolUse` turn counting · measurement (usage reader, continuous holdout, reporting norms) · failure-triggered review · install UX, install manifest, manifest-driven uninstall · deep security audit · all `graphify-offline` work (XML, BeanShell, PDF extraction).
