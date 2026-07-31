#!/usr/bin/env python3
"""Tiny jq replacement for hook scripts. stdlib only, py3.9+.

python3 is already spawned on every hook fire and is a hard dependency; jq was
a second one, and every runtime use of it in this project was a small JSON read
or write. This module replaces those uses so jq is not required at all.

  get <file|-> <key>...  print one line per key: strings raw, numbers/bools as
                         JSON, null or missing as an empty line. Dotted keys
                         descend (`a.b`). One line per key ALWAYS, so a bash
                         caller reading N values with N reads never shifts.
  set <file> <k>=<v>...  read-modify-write atomically at mode 0600. Values are
                         taken verbatim -- no shell-side JSON escaping, which
                         is what the `cat` heredocs this replaces got wrong.
                         Prefix a value with `json:` to type it (`json:5`).
  keys <file|->          print each top-level key on its own line. A missing
                         file prints nothing and exits 0, matching the
                         `jq ... 2>/dev/null` loops it replaces.

Exit 3 on unparseable or unreadable JSON so bash callers can fail loudly by
name instead of silently treating a broken state file as empty.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile


def _load(path):
    data = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    return json.loads(data)


def _dig(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _emit(value):
    if value is None:
        print()
    elif isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value))


def cmd_get(path, keys):
    obj = _load(path)
    for key in keys:
        _emit(_dig(obj, key))


def cmd_keys(path):
    try:
        obj = _load(path)
    except FileNotFoundError:
        return
    if not isinstance(obj, dict):
        raise SystemExit(3)
    for key in obj:
        print(key)


def cmd_set(path, pairs):
    try:
        obj = _load(path)
    except FileNotFoundError:
        obj = {}
    if not isinstance(obj, dict):
        raise SystemExit(3)
    for pair in pairs:
        key, _, value = pair.partition("=")
        parsed = json.loads(value[5:]) if value.startswith("json:") else value
        cur = obj
        parts = key.split(".")
        for part in parts[:-1]:
            cur = cur.setdefault(part, {})
        cur[parts[-1]] = parsed
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, indent=2)
            handle.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main(argv):
    if len(argv) < 3:
        print("usage: jsonio.py get <file|-> <key>... | set <file> <k>=<v>... "
              "| keys <file|->", file=sys.stderr)
        return 2
    try:
        if argv[1] == "get":
            cmd_get(argv[2], argv[3:])
        elif argv[1] == "set":
            cmd_set(argv[2], argv[3:])
        elif argv[1] == "keys":
            cmd_keys(argv[2])
        else:
            return 2
    except (json.JSONDecodeError, OSError):
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
