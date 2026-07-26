#!/usr/bin/env python3
# scripts/lib/coachtables.py
"""Vendored lookup tables from microsoft/AI-Engineering-Coach (MIT).

WHY THIS EXISTS
---------------
Four Coach rules (premium-waste, premium-for-lookup-questions,
auto-avoidance, session-drift) were skipped for years-in-dog-years on the
reason "upstream maintains a table we would have to snapshot, and a snapshot
would silently rot as models ship". That argument proves too much: the
vendored RULE files rot identically, and this project's answer to that was
scripts/sync-coach-rules.sh plus a _pin() that refuses to run an adapter
whose upstream text drifted. A table is not categorically different from a
predicate -- both are upstream artefacts, both are fetched by the same
script, both can be pinned by the same mechanism.

So the tables are vendored the way the rules are:

  * scripts/sync-coach-rules.sh fetches src/core/dsl/interpreter.ts at the
    pinned commit and writes a brace-balanced slice of each table, VERBATIM,
    to vendor/coach-rules/tables/. Verbatim matters: the vendored file stays
    diffable against upstream by eye.
  * Extraction FAILS LOUDLY if an anchor is missing, rather than writing an
    empty table -- an empty MODEL_TIERS would make modelTier() return 0 for
    every model and silently switch off three rules.
  * Each consuming adapter pins the SHA-256 of the table text it was written
    against (TABLE_PINS below). A table that changes -- upstream reprices a
    model, or someone edits the vendored file by hand -- stops the adapters
    that read it until a human acknowledges the change by updating the pin,
    exactly as a changed detect block does.

The one real asymmetry with rules: rule files are markdown fetched whole,
whereas these are TypeScript literals that must be sliced out. That is a
line item, handled below, not a reason to decline the work.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

TABLES_DIR = Path(__file__).resolve().parent.parent.parent / "vendor" / "coach-rules" / "tables"

MODEL_TIERS_FILE = "model-tiers.ts"
WORK_TYPE_PATTERNS_FILE = "work-type-patterns.ts"

# SHA-256 of each vendored table as the adapters in coach-rules-eval.py were
# written against it. This is the table analogue of _pin(): see the module
# docstring. Update deliberately, together with a re-read of the adapter.
TABLE_PINS = {
    MODEL_TIERS_FILE:
        "07ffa511c8c00c4ee926f15f7a0e4e66da0542a21913c60537f88f3db204221c",
    WORK_TYPE_PATTERNS_FILE:
        "b143966c6d90e8e96d1993ab8baab118d89d45db17d63b7ce3788de184e70d6c",
}

MODEL_TIERS_ANCHOR = "const MODEL_TIERS: Record<string, number> = {"
WORK_TYPE_PATTERNS_ANCHOR = "const WORK_TYPE_PATTERNS: [RegExp, string][] = ["

# classifyWorkText samples only the first 300 characters [upstream
# src/core/dsl/interpreter.ts:317] and falls back to 'feature' [:320].
WORK_TYPE_SAMPLE_CHARS = 300
WORK_TYPE_DEFAULT = "feature"


class TableError(ValueError):
    """Raised for a missing anchor, a missing file or a pin mismatch.

    A ValueError subclass on purpose: coach-rules-eval.py's main loop turns
    ValueError into a loud per-rule skip, so a broken table degrades to
    "these rules skipped, here is why" and never to a silent wrong answer.
    """


# ---------------------------------------------------------------------------
# Extraction (used by scripts/sync-coach-rules.sh, not at evaluation time)
# ---------------------------------------------------------------------------

def _balanced_slice(text, anchor, opener, closer):
    """The anchor plus everything through its matching closing bracket."""
    start = text.find(anchor)
    if start < 0:
        raise TableError(
            "anchor not found in upstream source: {!r}. Upstream renamed or "
            "restructured the table; extraction refuses to write an empty "
            "one".format(anchor))
    depth = 0
    index = start + len(anchor) - 1  # sit on the opener itself
    while index < len(text):
        char = text[index]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    raise TableError("unbalanced {!r} after anchor {!r}".format(opener, anchor))


# filename -> (anchor, opening bracket, closing bracket)
TABLE_SPECS = {
    MODEL_TIERS_FILE: (MODEL_TIERS_ANCHOR, "{", "}"),
    WORK_TYPE_PATTERNS_FILE: (WORK_TYPE_PATTERNS_ANCHOR, "[", "]"),
}


def extract_one(interpreter_ts, name):
    """The verbatim slice for ONE vendored table."""
    anchor, opener, closer = TABLE_SPECS[name]
    return _balanced_slice(interpreter_ts, anchor, opener, closer)


def extract_tables(interpreter_ts):
    """{filename: verbatim slice} for every table this project vendors."""
    return {name: extract_one(interpreter_ts, name) for name in TABLE_SPECS}


# ---------------------------------------------------------------------------
# Loading and parsing (evaluation time)
# ---------------------------------------------------------------------------

def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load(name, tables_dir=None):
    """Vendored table text, with its pin verified."""
    path = (Path(tables_dir) if tables_dir else TABLES_DIR) / name
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise TableError(
            "vendored table {} is missing or unreadable ({}) -- run "
            "scripts/sync-coach-rules.sh".format(name, exc))
    expected = TABLE_PINS.get(name)
    actual = sha256(text)
    if expected != actual:
        raise TableError(
            "vendored table {} changed since the adapters that read it were "
            "written (pinned {}, found {}). Re-read the adapters against the "
            "new table, then update TABLE_PINS -- this is the same contract "
            "_pin() enforces for a rule's detect block".format(
                name, expected[:12], actual[:12]))
    return text


_TIER_ENTRY_RE = re.compile(r"'([^']+)'\s*:\s*([0-9]*\.?[0-9]+)")


def model_tiers(tables_dir=None):
    """MODEL_TIERS as {model id substring: multiplier}, insertion-ordered.

    Order is load-bearing: modelTierLookup returns the FIRST key that is a
    substring of the normalised id, and upstream lists longer, more specific
    ids before their prefixes ('claude-opus-4.6-fast' before
    'claude-opus-4.6'). A dict comprehension over a sorted set would silently
    reprice models.
    """
    text = load(MODEL_TIERS_FILE, tables_dir)
    tiers = {}
    for key, value in _TIER_ENTRY_RE.findall(text):
        tiers[key] = float(value)
    if not tiers:
        raise TableError(
            "vendored MODEL_TIERS parsed to zero entries -- an empty table "
            "would make modelTier() return 0 for every model and silently "
            "switch off every rule that reads it")
    return tiers


_MODEL_PREFIX_RE = re.compile(r"^(openai/|anthropic/|google/)")
_MODEL_DATE_SUFFIX_RE = re.compile(r"-\d{4}-\d{2}-\d{2}$")


def normalize_model_id(raw):
    """Transcribes normalizeModelId [upstream src/core/dsl/interpreter.ts:361]."""
    out = _MODEL_PREFIX_RE.sub("", raw or "")
    out = _MODEL_DATE_SUFFIX_RE.sub("", out).lower().strip()
    return out or "untracked"


def model_tier(raw, tiers):
    """Transcribes modelTierLookup [upstream src/core/dsl/interpreter.ts:286].

    Note it does NOT use normalizeModelId's 'untracked' fallback -- it does
    the same prefix/date strip inline and returns 0 on no match.

    The date strip here is an EQUIVALENT MUTANT under mutation testing, and
    deliberately kept anyway. Matching is `key in ident`, so stripping a
    suffix can only ever remove a match, never create one -- deleting the
    strip cannot change any result. It stays because this function is a
    transcription of upstream's, and a transcription that quietly drops a
    line stops being diffable against the original. The observable version
    of the same strip is normalize_model_id(), which auto-avoidance uses to
    bucket ids, and that one IS covered by a test.
    """
    ident = _MODEL_PREFIX_RE.sub("", raw or "")
    ident = _MODEL_DATE_SUFFIX_RE.sub("", ident).lower()
    for key, value in tiers.items():
        if key in ident:
            return value
    return 0.0


_JS_REGEX_RE = re.compile(r"\[\s*/(.+?)/([a-z]*)\s*,\s*'([^']+)'\s*\]")


def work_type_patterns(tables_dir=None):
    """WORK_TYPE_PATTERNS as [(compiled, label)], in upstream's order.

    Order is load-bearing here too: classifyWorkText returns the FIRST match,
    so 'bug fix' beats 'test' for "fix the failing test".

    JS-to-Python regex translation is safe for these ten specifically --
    every one is plain alternation, \\b anchors and a literal ' ?'. There is
    no lookbehind, named group or unicode property among them. A pattern
    that used a JS-only construct would raise re.error here rather than be
    silently mistranslated, and the pin means such a change cannot arrive
    without a human seeing it.
    """
    text = load(WORK_TYPE_PATTERNS_FILE, tables_dir)
    out = []
    for pattern, flags, label in _JS_REGEX_RE.findall(text):
        compiled_flags = re.IGNORECASE if "i" in flags else 0
        try:
            out.append((re.compile(pattern, compiled_flags), label))
        except re.error as exc:
            raise TableError(
                "vendored work-type pattern for {!r} is not valid Python "
                "regex ({}) -- upstream used a JS-only construct".format(
                    label, exc))
    if not out:
        raise TableError(
            "vendored WORK_TYPE_PATTERNS parsed to zero entries -- every "
            "message would classify as 'feature' and session-drift could "
            "never fire")
    return out


def classify_work_text(text, patterns):
    """Transcribes classifyWorkText [upstream src/core/dsl/interpreter.ts:316]."""
    sample = text[:WORK_TYPE_SAMPLE_CHARS] if len(text) > WORK_TYPE_SAMPLE_CHARS else text
    for compiled, label in patterns:
        if compiled.search(sample):
            return label
    return WORK_TYPE_DEFAULT


def _main(argv):
    """`python3 coachtables.py extract <interpreter.ts> <dest-dir>`.

    Called by scripts/sync-coach-rules.sh. Prints the SHA-256 of each table
    it writes so a re-sync tells the operator exactly which TABLE_PINS entry
    to update.
    """
    if len(argv) != 4 or argv[1] != "extract":
        print("usage: coachtables.py extract <interpreter.ts> <dest-dir>",
              file=sys.stderr)
        return 2
    source = Path(argv[2]).read_text(encoding="utf-8")
    dest = Path(argv[3])
    dest.mkdir(parents=True, exist_ok=True)
    for name, slice_text in extract_tables(source).items():
        body = slice_text if slice_text.endswith("\n") else slice_text + "\n"
        (dest / name).write_text(body, encoding="utf-8")
        print("  vendored table: {}  sha256={}".format(name, sha256(body)))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
