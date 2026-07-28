#!/usr/bin/env python3
# NOTE: this docstring is raw (r"""). It quotes the backslash cases below
# verbatim, and `C:\Users` in a normal string is a truncated \U escape --
# a SyntaxError, hit for real while writing this file.
r"""Single source of truth for rendering a hook template's `__SL_SCRIPTS_DIR__`
placeholder into a real scripts directory.

Every hook-registration template (config/settings-hooks.json,
config/copilot-hooks.json, config/vscode-hooks.json) carries the placeholder
`__SL_SCRIPTS_DIR__` where the resolved store's `scripts` directory belongs.
install.sh renders them in five places (write the Copilot hook file, compare
against the on-disk one to decide "up to date", print the ACTION REQUIRED
block, render the VS Code JSON, render the Claude Code JSON) and README.md
documents a sixth for users who want to render one by hand.

Why this is a file and not a `sed` expression:

  `sed "s|__SL_SCRIPTS_DIR__|${SL_SCRIPTS}|g"` interpolates the replacement
  UNESCAPED into sed's own expression language, so a path containing any of
  sed's replacement metacharacters is silently mis-rendered. Measured, all
  three, end-to-end through install.sh:

    &  ->  "the whole matched text". A store under `/home/u/R&D/...` rendered
           `bash /home/u/R__SL_SCRIPTS_DIR__D/.../turn-counter.sh`, exit 0.
    \  ->  escape introducer. `/home/u/c\d/store` rendered as `/home/u/cd/store`
           (and GNU sed's `\U`/`\L` extensions turn a Windows `C:\Users\...`
           into `C:SERS...`), exit 0.
    |  ->  the chosen delimiter, so it ends the expression early:
           `sed: -e expression #1, char 49: unknown option to 's'`, and under
           install.sh's `set -euo pipefail` the install aborts half-done.

  The first two are this project's signature defect: a hook file that is
  still valid JSON, naming a path that does not exist, installed with a
  success message. It never fires and nothing ever says so.

  Escaping the replacement (backslash, then `&`, then the delimiter, in that
  order) does work, but it patches the class rather than removing it: it
  leaves six copies of a rule that is only correct while every one of them
  keeps the same delimiter and the same escape order. A literal
  byte-for-byte replacement has no metacharacters at all, so there is no
  rule left to get wrong.

Why Python rather than bash parameter expansion (`${tmpl//__SL_SCRIPTS_DIR__/$SL_SCRIPTS}`),
which is also literal: `content="$(cat "$f")"` strips ALL trailing newlines,
so the bash form cannot reproduce the template's final bytes, and
install.sh's "up to date" comparison at Step 4b diffs the rendered text
against the file on disk. Reading and writing bytes here keeps the output
byte-identical to what `sed` produced for an ordinary path, which is what
that comparison -- and tests/test-install-paths.sh -- assert on. python3 is
already a hard prerequisite of install.sh, so this adds no dependency.

The placeholder always sits inside a JSON string literal (all three templates
are JSON), so the replacement is JSON-escaped on the way in. Without that, a
literal replacement trades one broken hook for another: a Windows-style
`C:\Users\me\store\scripts` would inject raw backslashes, and `\U`/`\m` are
not valid JSON escapes -- the file stops parsing and the harness registers
nothing. paths.py renders MSYS-form paths (`/c/Users/...`) precisely so
backslashes do not normally get this far, but "normally" is the assumption
this project keeps getting caught by. `json.dumps(..., ensure_ascii=False)`
minus its surrounding quotes is the escape: it touches `"`, `\` and control
characters and nothing else, so for an ordinary path the output is
byte-identical to what `sed` produced, and a non-ASCII path keeps its UTF-8
bytes rather than being expanded to `\uXXXX`.

stdout is written through sys.stdout.buffer: no encoding surprises, and no
newline translation on Windows, so the template's own line endings pass
through exactly as `sed` passed them through.

THE SCRIPTS DIR ARRIVES ON STDIN, NEVER AS ARGV. This is load-bearing on
Git Bash, and getting it wrong is a regression CI caught: `sed` is an MSYS
binary, but python3 is a NATIVE Windows binary, and MSYS auto-converts any
POSIX-looking value crossing that boundary. Passing the scripts dir as argv
turned `/c/Users/RUNNER~1/.../store/scripts` into
`C:/Users/RUNNER~1/.../store/scripts` -- still a real, working path, but a
DIFFERENT SPELLING from the one sed used to write, which is what
tests/test-install-paths.sh asserts on and, worse, what
`sl_check_hook_fresh` in lib/config.sh matches TEXTUALLY to decide whether an
installed hook is current. A changed spelling makes a correctly-installed
hook look permanently stale: re-render every run, possibly a spurious
ACTION REQUIRED.

An environment variable is NOT an escape hatch -- MSYS converts those too
(CI-confirmed for `AGENT_LEARNING_HOME`; see paths.py's `_to_cli_string`).
`MSYS_NO_PATHCONV=1` / `MSYS2_ARG_CONV_EXCL=*` were explicitly rejected as a
product fix in fix round D, and could not work here anyway: the template
path argument still NEEDS conversion for a native Python to open it, so a
blanket per-process switch would break the very argument it is meant to
protect. stdin is a byte stream -- MSYS has no path conversion to apply to
it -- so it is the one channel that carries the replacement through
unaltered while argv conversion keeps working for the template path.

Usage:
    printf '%s' "$SL_SCRIPTS" | python3 render-template.py <template-file>

Renders to stdout. Exits non-zero, loudly, on a missing template, an empty
scripts dir, or a template that does not actually contain the placeholder --
each of which would otherwise produce a plausible-looking file registering
hooks that never run.
"""
from __future__ import annotations

import json
import sys

PLACEHOLDER = "__SL_SCRIPTS_DIR__"


def render(template_text: str, scripts_dir: str) -> str:
    """Replace every placeholder occurrence with a JSON-escaped scripts_dir.

    `str.replace` has no expression language, so no character in scripts_dir
    is special the way `&`, `\\` and the delimiter are to `sed`; the only
    transformation applied is the JSON escaping the surrounding string
    literal requires.
    """
    return template_text.replace(PLACEHOLDER, json.dumps(scripts_dir, ensure_ascii=False)[1:-1])


def _main(argv: list[str]) -> int:
    # Exactly one argument, on purpose: a second (the scripts dir, as it used
    # to be passed) must be a loud error, not a silently MSYS-converted path.
    # See the module docstring.
    if len(argv) != 1:
        print(
            "usage: printf '%s' \"$SL_SCRIPTS\" | "
            "render-template.py <template-file>",
            file=sys.stderr,
        )
        return 2

    template_path = argv[0]

    # Read as bytes: stdin carries the scripts dir exactly as bash wrote it,
    # with no argv/env path conversion applied on any platform. The rstrip
    # tolerates a caller using `echo` rather than `printf '%s'`, and matches
    # the \r discipline every other bash<->python boundary here already has.
    scripts_dir = sys.stdin.buffer.read().decode("utf-8").rstrip("\r\n")

    # Empty would render `bash /turn-counter.sh` -- a well-formed hook file
    # naming a path that cannot exist. Fail instead of emitting it.
    if not scripts_dir:
        print("render-template.py: scripts-dir is empty", file=sys.stderr)
        return 3

    try:
        # newline="" so line endings survive the round trip untranslated; the
        # templates are UTF-8 and their own bytes are reproduced exactly.
        with open(template_path, "r", encoding="utf-8", newline="") as fh:
            template_text = fh.read()
    except OSError as exc:
        print(f"render-template.py: cannot read {template_path}: {exc}", file=sys.stderr)
        return 3

    # A template that has lost its placeholder renders "successfully" into a
    # file naming whatever path was baked in when it drifted -- the same
    # silent non-firing hook, one step further upstream. Say so.
    if PLACEHOLDER not in template_text:
        print(
            f"render-template.py: {template_path} contains no "
            f"{PLACEHOLDER} placeholder; it is not a template",
            file=sys.stderr,
        )
        return 3

    sys.stdout.buffer.write(render(template_text, scripts_dir).encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
