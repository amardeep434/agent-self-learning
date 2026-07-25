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
from pathlib import Path, PurePath

APP_DIR_NAME = "agent-learning"

_SUBPATHS = {
    "state": ("state",),
    "skills": ("learned-skills",),
    "memory": ("memory",),
    "logs": ("logs",),
    "sessions_db": ("sessions", "search.db"),
    "config_file": ("self-learning.conf",),
    "scripts": ("scripts",),
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

    home = env.get("HOME")
    if not home:
        # Deferred minor 1 (upgraded to must-fix): falling through to
        # Path("") here previously normalized to Path(".") -- i.e. CWD --
        # so a bare shell with HOME unset would silently create the store
        # inside whatever directory happened to be current. That is the
        # exact silent-wrong-location class this module exists to prevent,
        # so refuse to guess instead of ever returning a CWD-relative path.
        extra = " or LOCALAPPDATA" if platform.startswith("win") else ""
        raise RuntimeError(
            "cannot resolve a home directory: $HOME is unset and no "
            f"override (AGENT_LEARNING_HOME, XDG_DATA_HOME{extra}) is set. "
            "Refusing to fall back to a path relative to the current "
            "working directory."
        )
    return Path(home) / ".local" / "share" / APP_DIR_NAME


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


def _to_cli_string(p: PurePath) -> str:
    """Render a path for the CLI (i.e. for bash consumers) as forward-slash text.

    The Python API (resolve_home/resolve_all) keeps returning real Path
    objects for Python callers -- only this CLI boundary stringifies.

    On native Windows, Path(...) is a WindowsPath, so plain str(p) yields
    backslashes (e.g. 'C:\\Users\\x'). Every bash consumer of this CLI
    (config.sh, install.sh, uninstall.sh) then treats those backslashes as
    escape characters, corrupting the path -- this was C1, proven by CI:
    `paths.py all` on windows-latest produced literal backslashes that broke
    every downstream `[[ -f ]]`/`mkdir -p`/string comparison.

    .as_posix() turns 'C:\\Users\\x' into 'C:/Users/x'. That is NOT the
    cygdrive form Git Bash's own tools print ('/c/Users/x'), but MSYS/Git
    Bash and native Windows tools both accept 'C:/Users/x' directly without
    a cygpath translation step -- forward slashes are simply not special to
    Win32 path parsing. .as_posix() alone is therefore sufficient here; a
    cygpath round-trip is unnecessary complexity this module (which must
    stay usable from both real Windows Python and any MSYS Python) should
    not add. This is verified in tests/test-paths.py using a PureWindowsPath
    so the assertion runs identically on every OS, since a real WindowsPath
    cannot be constructed on Linux.
    """
    return p.as_posix()


def _main(argv: list[str]) -> int:
    try:
        if len(argv) >= 2 and argv[0] == "get":
            resolved = resolve_all()
            key = argv[1]
            if key not in resolved:
                print(f"unknown path key: {key}", file=sys.stderr)
                return 2
            print(_to_cli_string(resolved[key]))
            return 0
        if argv and argv[0] == "all":
            for key, value in resolve_all().items():
                print(f"{key}={_to_cli_string(value)}")
            return 0
    except RuntimeError as exc:
        # resolve_home()'s loud failure (e.g. $HOME unset, no override) must
        # reach the caller as a clear, non-zero-exit error -- never as a
        # silently empty/CWD-relative path. See resolve_home() above.
        print(f"paths.py: {exc}", file=sys.stderr)
        return 3
    print("usage: paths.py get <key> | paths.py all", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
