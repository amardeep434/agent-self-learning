#!/usr/bin/env python3
"""session-start-context.py — deliver learned context at session start.

The read-back half of this project. Until 2026-07-30 there wasn't one: the
review pipeline distilled lessons into the store and nothing ever handed them
back to a working agent, so every component exited 0, doctor.sh reported
HEALTHY, and the system's entire purpose did not happen. See
docs/upstream-audit-2026-07-30.md.

Reads a SessionStart hook payload on stdin and prints ONE JSON object carrying
the learned memory as injected context. Reuses inject-agents-md.py's reader, so
the size advisory and the prompt-injection gate apply here too rather than being
reimplemented (and drifting).

WIRE FORMAT — two shapes, measured, not guessed:

    Claude Code / VS Code:
        {"hookSpecificOutput": {"hookEventName": "SessionStart",
                                "additionalContext": "..."}}
    Copilot CLI:
        {"additionalContext": "..."}

Emitting BOTH keys in one object was measured to work on all three, and is
still wrong. Claude Code ships a diagnostic written for exactly that mistake --
"Hook JSON output had unrecognized keys (ignored): ... Did you mean
hookSpecificOutput.additionalContext (with a hookEventName)?" -- which would
print on every session start forever. And Copilot's native runtime already
honours `hookSpecificOutput` on its preToolUse path, so if GitHub extends that
compat to sessionStart the trick becomes a real double injection.

HARNESS DISCRIMINATION is structural, from the payload's own key style, not from
which config file invoked us and not from sniffing a transcript:

    Copilot CLI      camelCase: sessionId, timestamp
    Claude Code      snake_case: session_id, transcript_path
    VS Code          snake_case: session_id, transcript_path

Claude Code and VS Code want the identical payload, so they need no distinction
from each other -- which is why this needs none of transcript.py's
`--harness auto` sniffing. VS Code additionally reads ~/.copilot/hooks, so a
Copilot-shaped registration also fires there; discriminating on the payload
rather than the config file is what stops that becoming a silent no-op.

EXACTLY ONE JSON OBJECT ON STDOUT. Copilot concatenates every non-progress
stdout line and runs a single JSON.parse; per its own docs, "If the leftover
output is empty, or fails to parse as JSON, the hook is treated as having
produced no output and falls through to default behavior." So one stray print
here silently kills the injection. Every diagnostic goes to
persist-failures.log, which doctor.sh surfaces -- never to stdout. This is the
one place where hard rule 2 and the wire format actively conflict.

Fires on every Claude Code `source` -- startup, resume, clear, compact, fork.
`compact` is deliberately NOT filtered out: compaction evicts the injected block
from the running context, and re-firing there is the only way a long session
keeps its learned context. Hermes does the same thing deliberately
(agent/system_prompt.py:576-585 invalidate_system_prompt, which also reloads
memory from disk).
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import paths  # noqa: E402

_HEADING = "## Learned context (from past sessions)"

# Payload keys that identify Copilot CLI. Its native runtime builds the
# sessionStart input as {sessionId, timestamp, cwd, source, initialPrompt}
# (camelCase); Claude Code and VS Code both use snake_case with session_id and
# transcript_path. Checked as a set rather than on one key so a single renamed
# field does not silently flip every session to the wrong wire shape.
_COPILOT_KEYS = ("sessionId", "timestamp")
_NESTED_KEYS = ("session_id", "transcript_path", "hook_event_name")


def _load_injector():
    """Load inject-agents-md.py by path for its gated memory reader.

    Hyphenated filename, so not importable as a module name -- same by-path
    loader shape lib/transcript.py uses for scan-threats.py. Importing rather
    than reimplementing keeps ONE definition of the size advisory and the
    prompt-injection gate.
    """
    path = Path(__file__).resolve().parent / "inject-agents-md.py"
    spec = importlib.util.spec_from_file_location("sl_inject_agents_md", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load inject-agents-md.py from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _log_failure(message: str) -> None:
    """Append one line to ${SL_LOG_DIR}/persist-failures.log.

    The hook is the only caller and its stdout is reserved for the wire format,
    so this log is the ONLY channel by which a degraded session-start can be
    noticed. Never raises: an unwritable log must not also break the injection.
    """
    try:
        log_dir = os.environ.get("SL_LOG_DIR")
        if not log_dir:
            log_dir = str(paths.resolve_all()["logs"])
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
        from isotime import now_iso
        with open(Path(log_dir) / "persist-failures.log", "a",
                  encoding="utf-8", newline="\n") as handle:
            handle.write(f"{now_iso()} session-start-context: {message}\n")
    except (OSError, ImportError, KeyError, RuntimeError):
        pass


def wants_flat_shape(payload: dict) -> bool:
    """True for Copilot CLI (flat `additionalContext`), False for the nested form.

    Defaults to the NESTED shape when the payload is unrecognisable. That
    default is chosen deliberately: guessing nested on Copilot loses the
    injection silently, while guessing flat on Claude Code loses the injection
    AND prints an unrecognized-keys warning to the user on every session. The
    quieter wrong answer is the wrong one to prefer -- but a mis-detected
    Copilot session is at least reported below, whereas Claude Code's warning
    is not ours to suppress.
    """
    if any(key in payload for key in _NESTED_KEYS):
        return False
    return any(key in payload for key in _COPILOT_KEYS)


def build_context(memory_dir: Path) -> str:
    """Return the text to inject, or "" when there is nothing to say."""
    injector = _load_injector()
    memory = injector.read_memory(memory_dir)
    if not memory:
        return ""
    return f"{_HEADING}\n\n{memory}"


def main() -> int:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    payload: dict = {}
    if raw.strip():
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                payload = parsed
            else:
                _log_failure(
                    f"hook payload parsed to {type(parsed).__name__}, not an object -- "
                    "cannot identify the harness, defaulting to the nested wire shape"
                )
        except json.JSONDecodeError as exc:
            _log_failure(
                f"hook payload is not JSON ({exc}) -- cannot identify the harness, "
                "defaulting to the nested wire shape"
            )

    try:
        memory_dir = Path(os.environ.get("SL_MEMORY_DIR") or paths.resolve_all()["memory"])
    except (KeyError, OSError, RuntimeError) as exc:
        # No store means no context. Say so and emit a well-formed empty object:
        # printing nothing is indistinguishable from the hook never running.
        _log_failure(f"cannot resolve the memory directory ({exc}) -- injected nothing")
        print("{}")
        return 0

    try:
        context = build_context(memory_dir)
    except (ImportError, OSError, RuntimeError) as exc:
        _log_failure(f"cannot build the learned-context block ({exc}) -- injected nothing")
        print("{}")
        return 0

    if not context:
        # A genuinely empty store is not a failure -- a fresh install has
        # nothing to inject and must not log, or doctor.sh reports UNHEALTHY on
        # every session of a new install.
        print("{}")
        return 0

    if wants_flat_shape(payload):
        document = {"additionalContext": context}
    else:
        document = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": context,
            }
        }
    # One object, nothing else. json.dumps never emits a trailing newline issue
    # for Copilot's concatenate-then-parse, but print's newline is fine: its
    # parser trims before parsing.
    print(json.dumps(document))
    return 0


if __name__ == "__main__":
    # A catch-all around main(), because this file's stdout IS a wire contract:
    # "EXACTLY ONE JSON OBJECT ON STDOUT". Measured before this guard, an
    # uncaught RuntimeError from paths.py (raised for an unresolvable home, and
    # NOT one of the types the handlers caught) produced 0 bytes on stdout and a
    # traceback -- the docstring's own non-negotiable broken by the error path.
    # Any escape here is a bug, but a bug must still not violate the contract.
    # `Exception`, NOT `BaseException`: sys.exit() raises SystemExit, which is a
    # BaseException, so catching that caught main()'s own normal exit and printed
    # a SECOND "{}" after the real object. Two JSON objects concatenate into
    # invalid JSON and Copilot then discards the injection silently -- this guard
    # briefly produced the exact failure it exists to prevent. Measured: 2 lines
    # on stdout, json.load() refused the result.
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 -- deliberate; see above
        try:
            _log_failure(f"unhandled {type(exc).__name__}: {exc} -- injected nothing")
        except BaseException:
            pass
        print("{}")
        sys.exit(0)
