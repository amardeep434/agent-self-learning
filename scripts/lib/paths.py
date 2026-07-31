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
from pathlib import Path, PurePath, PureWindowsPath

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
        # A leading "/" counts as absolute even where ntpath disagrees
        # (Python 3.13 made drive-less rooted paths non-absolute on Windows):
        # this project's Windows execution runs under Git Bash/MSYS, where
        # /tmp/... is the normal absolute form and is converted before native
        # python.exe sees it (see the module docstring). The guard exists to
        # refuse genuinely CWD-relative values like "relative/dir", not to
        # police drive semantics.
        if not os.path.isabs(explicit) and not explicit.startswith("/"):
            # Same refusal as the $HOME-unset case below, for the same reason: a
            # relative override resolves against the caller's CWD, so the store
            # silently moves between invocations of the same install.
            raise RuntimeError(
                "AGENT_LEARNING_HOME must be an absolute path, got: "
                f"{explicit}. Refusing a path relative to the current working "
                "directory."
            )
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


def _to_msys_path(p: PureWindowsPath) -> str:
    """Render a WindowsPath in MSYS/cygdrive form: 'C:/Users/x' -> '/c/Users/x'.

    Pure Python, derived from `.drive` and `.parts` -- deliberately NOT a
    `cygpath` subprocess call (see `_to_cli_string`'s docstring for why).
    Falls back to plain `.as_posix()` for a driveless path or a UNC share
    (e.g. '\\\\server\\share\\x'), neither of which has a single-drive-letter
    cygdrive-form equivalent to convert to.
    """
    drive = p.drive
    if len(drive) == 2 and drive[1] == ":":
        letter = drive[0].lower()
        rest = "/".join(p.parts[1:])
        return f"/{letter}/{rest}" if rest else f"/{letter}"
    return p.as_posix()


def _to_cli_string(p: PurePath, *, is_windows: bool | None = None, msystem: str | None = None) -> str:
    """Render a path for the CLI (i.e. for bash consumers) as forward-slash text.

    The Python API (resolve_home/resolve_all) keeps returning real Path
    objects for Python callers -- only this CLI boundary stringifies.

    On native Windows, Path(...) is a WindowsPath, so plain str(p) yields
    backslashes (e.g. 'C:\\Users\\x'). Every bash consumer of this CLI
    (config.sh, install.sh, uninstall.sh) then treats those backslashes as
    escape characters, corrupting the path -- this was C1, proven by CI:
    `paths.py all` on windows-latest produced literal backslashes that broke
    every downstream `[[ -f ]]`/`mkdir -p`/string comparison. C1's fix
    (.as_posix(), unconditionally) is necessary but was not sufficient --
    see below.

    Fix round D, blocker (b): round A's diagnosis of the SUBSEQUENT Windows
    CI failure was wrong. The actual failure was not an escaping bug at all:
        FAIL: AGENT_LEARNING_HOME drives SL_MEMORY_DIR
          (expected '/tmp/al/memory', got 'C:/Users/RUNNER~1/AppData/Local/Temp/al/memory')
    MSYS2 (Git Bash) auto-converts POSIX-looking env values into Win32 form
    BEFORE native python.exe ever sees them: `AGENT_LEARNING_HOME=/tmp/al`
    arrives inside Python already as `C:\\Users\\...\\Temp\\al`.
    `.as_posix()` then faithfully echoes that Win32-flavoured path back out
    -- correct behavior for .as_posix() itself, but a round-trip FLAVOUR
    mismatch against what bash originally passed in, not a fixable
    escaping/quoting bug.

    The fix is conditional: only inside an actual MSYS2/Git-Bash shell (the
    one environment that performed that conversion, and the one whose own
    tools expect cygdrive-form paths back) do we emit '/c/Users/...' MSYS
    form. Detected via `os.name == "nt"` (this is a real Windows Python,
    native or MSYS-launched) AND `MSYSTEM` being set in the environment --
    Git Bash / MSYS2 always sets MSYSTEM (e.g. "MINGW64"); native cmd.exe
    and PowerShell never do. Outside that combination (native Windows
    Python invoked from cmd/PowerShell, or any POSIX platform) the plain
    `.as_posix()` form from C1 is kept unchanged -- native Windows tools and
    MSYS/Git Bash tools both accept 'C:/Users/x' directly, without a cygpath
    translation step, so nothing regresses for that caller.

    Deliberately NOT implemented via a `cygpath` subprocess call: that would
    add a PATH dependency and a subprocess spawn to the hot hook path for
    every single resolved path. `_to_msys_path` derives the same result in
    pure Python from `PureWindowsPath.drive` + `.parts`.

    Both branches are unit-tested in tests/test-paths.py using
    PureWindowsPath (with `is_windows=`/`msystem=` passed explicitly) so
    both run identically on Linux, macOS, and Windows -- a real WindowsPath
    cannot be constructed on a non-Windows OS, but PureWindowsPath can be,
    on any OS, and the optional keyword args let a test force either branch
    without needing to monkeypatch os.name/os.environ globally.
    """
    if is_windows is None:
        is_windows = os.name == "nt"
    if msystem is None:
        msystem = os.environ.get("MSYSTEM")
    if is_windows and msystem:
        return _to_msys_path(PureWindowsPath(str(p)))
    return p.as_posix()


def _main(argv: list[str]) -> int:
    # Fix round E: force LF-only line endings on stdout regardless of
    # platform. On native Windows, Python's default text-mode sys.stdout
    # performs universal-newline translation (writing "\n" actually emits
    # "\r\n") even when the destination is a pipe rather than a console --
    # this is Python's own io.TextIOWrapper behavior, unrelated to and not
    # fixed by anything MSYS/Git-Bash does. Every bash consumer of this CLI
    # (config.sh, install.sh, uninstall.sh) reads this output either via
    # `while IFS='=' read -r k v; do ... done < <(python3 paths.py all)` or
    # via `$(... paths.py get key)` command substitution. In BOTH cases bash
    # strips only the trailing "\n" record terminator -- never a "\r"
    # immediately preceding it -- so without this fix, every single resolved
    # path value would carry an invisible trailing "\r" on Windows. That
    # corrupts every downstream use: a directory named "...logs" is not the
    # same directory as "...logs\r" (silently making every store subpath
    # this project resolves through config.sh/install.sh's read loops
    # unreachable/wrong on Windows, the exact silent-wrong-location class
    # this project exists to eliminate); and where a resolved path is
    # substituted into a JSON template (install.sh's copilot-hooks.json
    # rendering), the embedded raw "\r" is an unescaped control character
    # inside a JSON string -- invalid per RFC 8259 -- which breaks strict
    # JSON parsers like jq downstream. `reconfigure` is Python 3.7+ (this
    # project's floor is 3.9); guarded in case a caller ever replaces
    # sys.stdout with something that does not support it.
    try:
        sys.stdout.reconfigure(newline="\n")
    except (AttributeError, ValueError):
        pass
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
        if len(argv) >= 2 and argv[0] == "canon":
            # Fix round F: tests/lib/path-compare.sh's sl_canon_path used to
            # reimplement path canonicalization independently in an inline
            # `python3 -c 'import os,sys; print(os.path.realpath(...))'` --
            # a SECOND, divergent rendering of the same underlying value,
            # the exact duplicated-copy pattern that caused the round-D
            # isotime regression. That inline version printed via plain
            # str()/print(), which on native Windows renders a WindowsPath
            # with backslashes (`os.path.realpath` returns a native-flavour
            # string) -- a THIRD path spelling next to the MSYS form the
            # rest of this project's CLI output now consistently uses,
            # observed directly in CI: `sl_canon_path` returned
            # 'C:\Users\...\real' where every other resolved value in the
            # same run was already in '/c/Users/...' MSYS form. This
            # subcommand is the single place that combines realpath
            # (works on a nonexistent path too, needed since canonicalizing
            # a path a test hasn't created yet is a real use case) with
            # THIS module's own _to_cli_string rendering, so bash callers
            # get exactly the same spelling convention for a canonicalized
            # path as for any other resolved key -- one implementation,
            # not two.
            print(_to_cli_string(Path(os.path.realpath(argv[1]))))
            return 0
    except RuntimeError as exc:
        # resolve_home()'s loud failure (e.g. $HOME unset, no override) must
        # reach the caller as a clear, non-zero-exit error -- never as a
        # silently empty/CWD-relative path. See resolve_home() above.
        print(f"paths.py: {exc}", file=sys.stderr)
        return 3
    print("usage: paths.py get <key> | paths.py all | paths.py canon <path>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
