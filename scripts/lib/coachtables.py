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
PROFANITY_FILE = "profanity-sha256.txt"

# The npm version upstream pins [upstream package.json:359]. This project
# targets the same dictionary upstream's containsProfanity() resolves to.
PROFANITY_PACKAGE = "leo-profanity"
PROFANITY_VERSION = "1.9.0"

# SHA-256 of each vendored table as the adapters in coach-rules-eval.py were
# written against it. This is the table analogue of _pin(): see the module
# docstring. Update deliberately, together with a re-read of the adapter.
TABLE_PINS = {
    MODEL_TIERS_FILE:
        "07ffa511c8c00c4ee926f15f7a0e4e66da0542a21913c60537f88f3db204221c",
    WORK_TYPE_PATTERNS_FILE:
        "b143966c6d90e8e96d1993ab8baab118d89d45db17d63b7ce3788de184e70d6c",
    PROFANITY_FILE:
        "1a870c16564186ddbfce8306a8901d7e030091abf25f5361392ad8d9cfb65704",
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


# ---------------------------------------------------------------------------
# Profanity dictionary.
#
# Upstream's src/core/profanity.ts is 46 lines and contains NO wordlist; its
# header says the plaintext list deliberately lives in an external package
# and is not committed. It delegates to leo-profanity (MIT, pinned at 1.9.0
# in upstream's package.json:359). The skip that said "evaluating it would
# mean inventing a moderation wordlist" was therefore wrong twice: nothing
# would be invented, and upstream invents nothing either.
#
# Microsoft's real objection -- keep the slurs out of the repository -- is
# preserved here rather than discarded. leoProfanity.check() is exact
# whole-word set membership after a two-step sanitize, so SHA-256 hashes of
# the words behave identically to the words and commit none of them.
# ---------------------------------------------------------------------------

# sanitize(): lowercase, then replace '.' and ',' with a space
# [leo-profanity 1.9.0 src/index.js sanitize()]. check() then splits on
# /[^ ]+/ and tests exact set membership. No stemming, no substring match --
# which is precisely why hashing is behaviour-preserving.
_PROFANITY_PUNCT_RE = re.compile(r"[.,]")
_PROFANITY_SPLIT_RE = re.compile(r"[^ ]+")

# stripCode(): drop fenced blocks and inline-backtick spans BEFORE checking
# [upstream src/core/profanity.ts:18-20]. Without it every code snippet with
# a rude identifier in it becomes a false positive.
_FENCED_CODE_RE = re.compile(r"```.*?```", re.S)
_INLINE_CODE_RE = re.compile(r"`[^`]+`")


def profanity_hashes(tables_dir=None):
    """The vendored dictionary as a set of SHA-256 hex digests."""
    text = load(PROFANITY_FILE, tables_dir)
    digests = {
        line.strip() for line in text.splitlines()
        if line.strip() and not line.startswith("#")
    }
    if not digests:
        raise TableError(
            "vendored profanity dictionary parsed to zero entries -- the "
            "rule would evaluate and never fire")
    return digests


def strip_code(text):
    """Transcribes stripCode [upstream src/core/profanity.ts:18-20]."""
    return _INLINE_CODE_RE.sub("", _FENCED_CODE_RE.sub("", text))


def contains_profanity(text, digests):
    """Transcribes containsProfanity [upstream src/core/profanity.ts:24-27]
    over leoProfanity.check()'s exact-word semantics."""
    if not text:
        return False
    cleaned = _PROFANITY_PUNCT_RE.sub(" ", strip_code(text).lower())
    for word in _PROFANITY_SPLIT_RE.findall(cleaned):
        if hashlib.sha256(word.encode("utf-8")).hexdigest() in digests:
            return True
    return False


PROFANITY_HEADER = """\
# {package} {version} -- dictionary/default.json, SHA-256 of each entry.
#
# MIT License, Copyright (c) 2017 Nathachai Thongniran.
# Source: https://registry.npmjs.org/{package}/-/{package}-{version}.tgz
# Upstream (microsoft/AI-Engineering-Coach) depends on this exact version --
# package.json:359 -- and deliberately keeps the plaintext list OUT of its
# repository (src/core/profanity.ts header). This project keeps that property
# by committing hashes instead of words: leoProfanity.check() is exact
# whole-word set membership after lowercasing and replacing '.' and ',' with
# spaces, so hashing each entry preserves the behaviour exactly and commits
# no slurs. Regenerated by scripts/sync-coach-rules.sh.
#
# Entries: {count}, sorted. One lowercase hex SHA-256 per line.
"""


def hash_dictionary(words):
    """The vendored profanity file's text for a list of dictionary words."""
    if not isinstance(words, list) or not words:
        raise TableError("profanity dictionary is empty or not a list")
    for word in words:
        # A multi-word or mixed-case entry would not survive hashing, because
        # check() only ever tests single lowercase whitespace-delimited
        # tokens. Fail loudly rather than vendor entries that can never match.
        if not isinstance(word, str) or word != word.lower() or " " in word:
            raise TableError(
                "profanity dictionary entry is not a single lowercase token; "
                "hashing would silently drop it")
    digests = sorted(sha256(word) for word in words)
    header = PROFANITY_HEADER.format(
        package=PROFANITY_PACKAGE, version=PROFANITY_VERSION,
        count=len(digests))
    return header + "\n".join(digests) + "\n"


def _main(argv):
    """`coachtables.py extract <interpreter.ts> <dest-dir>` or
    `coachtables.py hash-dictionary <default.json> <dest-dir>`.

    Called by scripts/sync-coach-rules.sh. Prints the SHA-256 of each file it
    writes so a re-sync tells the operator exactly which TABLE_PINS entry to
    update.
    """
    if len(argv) != 4 or argv[1] not in ("extract", "hash-dictionary"):
        print("usage: coachtables.py extract <interpreter.ts> <dest-dir>\n"
              "       coachtables.py hash-dictionary <default.json> <dest-dir>",
              file=sys.stderr)
        return 2
    dest = Path(argv[3])
    dest.mkdir(parents=True, exist_ok=True)
    if argv[1] == "hash-dictionary":
        import json
        body = hash_dictionary(json.loads(Path(argv[2]).read_text(encoding="utf-8")))
        (dest / PROFANITY_FILE).write_text(body, encoding="utf-8")
        print("  vendored table: {}  sha256={}".format(PROFANITY_FILE, sha256(body)))
        return 0
    source = Path(argv[2]).read_text(encoding="utf-8")
    for name, slice_text in extract_tables(source).items():
        body = slice_text if slice_text.endswith("\n") else slice_text + "\n"
        (dest / name).write_text(body, encoding="utf-8")
        print("  vendored table: {}  sha256={}".format(name, sha256(body)))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
