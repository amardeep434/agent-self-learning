#!/usr/bin/env python3
r"""Rewrite the install location out of a rendered hook file, so install.sh can
tell "ours, just installed somewhere else" from "ours, edited by the user".

This is the inverse of render-template.py: that one turns
`__SL_SCRIPTS_DIR__/copilot-session-review.sh` into a real path, this one turns
a real path back into the placeholder. install.sh Step 4b compares the result
against the template verbatim; if they match, the only difference between the
installed hook and ours is WHERE it points, so it can be re-rendered silently.
If they do not match, the user changed something and gets a .bak. Normalizing
too little therefore costs a spurious .bak and a false "had local
modifications" message on every store relocation; normalizing too much
silently discards a real customization.

Why this is a file and not a `sed` expression:

  install.sh used `sed 's#[^" ]*/copilot-session-review\.sh#...#g'`. The
  character class excludes the space, so a store path containing one is only
  partly matched. Measured:

    in   "bash": "bash /home/u/My Store/scripts/copilot-session-review.sh"
    out  "bash": "bash /home/u/My __SL_SCRIPTS_DIR__/copilot-session-review.sh"

  The stray `/home/u/My ` never appears in the template, so relocating a store
  whose path contains a space was reported as "UPDATED (had local
  modifications)" with a backup file, instead of "UPDATED (was stale)" --
  measured end-to-end through install.sh, against the identical run with a
  space-free path, which correctly reported it as stale.

  Widening the class does not work; both obvious widenings were measured on
  the two values config/copilot-hooks.json actually contains:

    [^"]*       eats the interpreter too -- `"bash": "bash /p/x.sh"` normalizes
                to `"bash": "__SL_SCRIPTS_DIR__/x.sh"`, which matches no
                template, so EVERY hook file would classify as user-edited.
    bash [^"]*  gets the `bash` value right and leaves the `powershell` one
                (`bash -lc \"<path>\"`) completely unmatched, because the
                anchor text there is `\"`, not `bash `.

  There is no character class that covers both, because the real boundary is
  not a character: it is "where does the path begin", and a path may contain
  spaces while the value around it also uses spaces as argument separators.
  That question needs a scan, not a class.

Why not parse the JSON, rewrite the values and re-serialize -- which would at
least drop the `\"` escaping from the problem:

  1. install.sh compares this output against config/copilot-hooks.json BYTE FOR
     BYTE (`[[ "$(_normalize_copilot_hook "$dst")" == "$(cat "$src")" ]]`).
     `json.dumps` reproduces the template's exact formatting only by
     coincidence, and the moment it does not, every hook file classifies as
     user-edited -- the same defect being fixed. Making it robust means
     normalizing BOTH sides through the round trip, which also reclassifies a
     merely whitespace-different user file from "edited" (keeps a .bak) to
     "stale" (no .bak). That is a data-loss-shaped behaviour change nobody
     asked for.
  2. It does not solve the hard part. Inside the decoded value the path-start
     ambiguity is exactly the same; all JSON parsing removes is the `\"`
     escaping, which the scan below handles by refusing to cross `"` or `\`.
  3. A hand-edited hook file with a trailing comma is not valid JSON, and must
     still be CLASSIFIED (as "not ours" / "edited"), not crash the install.
     Text scanning degrades into "no match, leave it alone"; a parser raises.

The scan. For each occurrence of `/<script-name>`, walk backwards to the
RIGHTMOST index p that could begin an absolute path:

  - p starts a path: text[p] is `/`, or text[p:p+2] is a drive letter and
    colon followed by `/` (`C:/Users/...`). Both Windows spellings paths.py
    can emit are covered -- the MSYS form `/c/Users/...` is just the first
    case, and the native form needs the drive letter or `C:` is left behind as
    a stray prefix, which is the original defect wearing a different hat.
  - the character before p is a boundary: start of text, a space or tab
    (argument separator), or a quote (the JSON string opening, or the shell
    quote in the powershell value, whose preceding `\` is also excluded from
    the body below so the scan cannot reach past it).
  - text[p:i] contains no `"` and no `\`, so a match can never span two JSON
    string literals.

RIGHTMOST, not leftmost, is the load-bearing choice: it takes the SHORTEST
plausible path. `"bash /usr/bin/env bash /home/u/store/scripts/x.sh"` normalizes
to `bash /usr/bin/env bash __SL_SCRIPTS_DIR__/x.sh` -- which differs from the
template, so the user's `/usr/bin/env` survives in a .bak. Leftmost would have
swallowed it and reported the file as merely stale. A colon is deliberately NOT
a boundary, so `C:/Users/...` is preferred over the `/Users/...` inside it.

Not handled, deliberately: a path written with literal backslash separators
(`C:\\Users\\...\\x.sh` in the JSON). paths.py emits `/c/...` or `C:/...` and
never that form, and admitting `\` into the path body is precisely what stops
the scan escaping a JSON string. Such a file classifies as "ours, edited" --
a spurious .bak, which is the safe direction to be wrong in.

Usage:
    normalize-hook-path.py <hook-file> <script-basename>

Writes the normalized text to stdout. Bytes in, bytes out: line endings and
the file's final newline survive untouched, because install.sh's comparison is
on bytes. Exits non-zero, loudly, on a missing or unreadable file.
"""
from __future__ import annotations

import sys

PLACEHOLDER = "__SL_SCRIPTS_DIR__"

# Characters that may precede the first character of a path. A `\` is absent on
# purpose: in the powershell value the path is preceded by `\"`, and it is the
# `"` that is matched here.
BOUNDARY = (" ", "\t", '"', "'")

# Characters that can never appear inside the path, because crossing one would
# mean leaving the JSON string literal the path lives in.
FORBIDDEN_IN_PATH = ('"', "\\")


def _starts_path(text: str, p: int) -> bool:
    """True if a path could begin at index p: `/...` or `C:/...`."""
    if text[p] == "/":
        return True
    return (
        p + 2 < len(text)
        and text[p].isascii()
        and text[p].isalpha()
        and text[p + 1] == ":"
        and text[p + 2] == "/"
    )


def _path_start(text: str, end: int) -> int | None:
    """Rightmost index in [0, end] where the path ending at `end` begins.

    `end` is the index of the `/` separating the directory from the script
    name. Returns None when nothing before `end` looks like an absolute path --
    an already-normalized file, or a relative path we must not touch.
    """
    for p in range(end, -1, -1):
        if any(c in text[p:end] for c in FORBIDDEN_IN_PATH):
            # Walked out of the string literal; nothing further left can be
            # part of this path either.
            return None
        if not _starts_path(text, p):
            continue
        if p == 0 or text[p - 1] in BOUNDARY:
            return p
    return None


def _spans(text: str, script_name: str):
    """Yield (match_start, path_start_or_None) for each `/<script_name>`.

    The single place the scan above is driven from. `normalize` and
    `find_paths` are two readings of the same answer, so a path either tool
    can find is a path the other agrees about by construction.
    """
    needle = "/" + script_name
    cursor = 0
    while True:
        i = text.find(needle, cursor)
        if i < 0:
            return
        yield i, _path_start(text, i)
        cursor = i + len(needle)


def normalize(text: str, script_name: str) -> str:
    """Replace every install path in front of `script_name` with PLACEHOLDER."""
    needle = "/" + script_name
    out = []
    cursor = 0
    for i, start in _spans(text, script_name):
        if start is None:
            # Leave it exactly as found: already normalized, or relative.
            out.append(text[cursor : i + len(needle)])
        else:
            out.append(text[cursor:start])
            out.append(PLACEHOLDER)
            out.append(needle)
        cursor = i + len(needle)
    out.append(text[cursor:])
    return "".join(out)


def find_paths(text: str, script_name: str) -> list[str]:
    """Every DIRECTORY that `script_name` is invoked from, in file order.

    install.sh's "UPDATED (was stale)" branch prints where the hook used to
    point, and that message is the only record a user gets of what changed.
    It used to recover the directory with a sed expression of its own --
    `s#.*"bash": "bash \\(.*\\)/copilot-session-review\\.sh".*#\\1#p` -- which
    is a SECOND hand-rolled answer to "where does the path begin", the exact
    question this module exists because a character class cannot answer. It
    duly broke the moment the hook command gained shell quoting: the trailing
    `.sh"` no longer matched `.sh'"`, so the branch printed `<unknown>` while
    still claiming success. Same scan, one definition, so the message cannot
    drift from the rewrite again.
    """
    return [
        text[start:i]
        for i, start in _spans(text, script_name)
        if start is not None
    ]


def _main(argv: list[str]) -> int:
    print_path = False
    if argv and argv[0] == "--print-path":
        print_path = True
        argv = argv[1:]

    if len(argv) != 2:
        print(
            "usage: normalize-hook-path.py [--print-path] <hook-file> "
            "<script-basename>",
            file=sys.stderr,
        )
        return 2

    hook_path, script_name = argv

    # A script name with a separator in it would make the scan's "rightmost
    # path start" question meaningless. Callers pass a basename.
    if "/" in script_name or "\\" in script_name or not script_name:
        print(
            f"normalize-hook-path.py: {script_name!r} is not a bare basename",
            file=sys.stderr,
        )
        return 2

    try:
        # newline="" so CRLF survives the round trip: install.sh diffs bytes.
        with open(hook_path, "r", encoding="utf-8", newline="") as fh:
            text = fh.read()
    except OSError as exc:
        print(
            f"normalize-hook-path.py: cannot read {hook_path}: {exc}",
            file=sys.stderr,
        )
        return 3

    if print_path:
        # One directory per line, LF-terminated regardless of the file's own
        # line endings: this output is read by `$( ... )` in install.sh, not
        # diffed against bytes, and a CR riding along would land in the middle
        # of the "previously ..." message. Prints nothing at all (exit 0) when
        # no path was found, so the caller's `${VAR:-<unknown>}` still fires.
        out = "".join(p + "\n" for p in find_paths(text, script_name))
    else:
        out = normalize(text, script_name)
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
