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
