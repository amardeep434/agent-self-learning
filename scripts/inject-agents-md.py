#!/usr/bin/env python3
"""inject-agents-md.py — idempotently maintain the self-learning managed block
in an AGENTS.md file.

Usage: python3 inject-agents-md.py <target-agents-md-path>

Reads (env-configurable, falling back to lib/paths.py's resolver -- same as
every other consumer in this project -- rather than a hardcoded ~/.claude
default, which would be wrong-location on Copilot CLI and VS Code):
    SL_MEMORY_DIR -> MEMORY.md lines
    SL_SKILLS_DIR -> <name>/SKILL.md frontmatter

Everything outside the marker pair is preserved byte-for-byte.
"""

import importlib.util
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import paths  # noqa: E402
import skill_layout  # noqa: E402  (single definition of the skill-directory layout; see lib/skill_layout.py)

BEGIN = "<!-- BEGIN self-learning:managed -->"
END = "<!-- END self-learning:managed -->"

# Advisory only -- the size at which MEMORY.md is worth consolidating, NOT a
# truncation point. Hermes uses this same 2200 as a write-side budget that
# refuses the write and tells the agent to consolidate
# (tools/memory_tool.py:165, rejection :426-437); its read path never
# truncates either.
#
# This used to be `MAX_MEMORY_CHARS`, applied as `read_text(...)[:2200]`.
# Measured 2026-07-30 against the real store that slice injected 10% of a
# 20752-byte MEMORY.md and silently discarded 89% of it, mid-entry -- and
# because the file is append-ordered, what it discarded was the NEWEST
# lessons, i.e. precisely the content most worth delivering. No ellipsis, no
# log line, nothing doctor.sh could surface: hard rule 2's exact failure
# class, dormant only because this script had no caller.
#
# The budget is not copied to our write path: MEMORY.md is already ~9x over
# it, so enforcing 2200 there would reject every future append, and
# persist-proposal.py already bounds accumulated growth loudly via
# MAX_MEMORY_FILE_BYTES. So over-budget is reported and everything is still
# injected. Override with SL_MEMORY_INJECT_BUDGET (bytes).
DEFAULT_MEMORY_INJECT_BUDGET = 2200


def _log_advisory(message: str) -> None:
    """Append one line to ${SL_LOG_DIR}/persist-failures.log.

    Same log, same line shape as persist-proposal.py and skill-lifecycle.py,
    so doctor.sh needs no new parsing. Never raises: an unwritable log
    directory must not turn an advisory into a failed injection.
    """
    try:
        log_dir = os.environ.get("SL_LOG_DIR")
        if not log_dir:
            log_dir = str(paths.resolve_all()["logs"])
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        from isotime import now_iso
        with open(Path(log_dir) / "persist-failures.log", "a",
                  encoding="utf-8", newline="\n") as handle:
            handle.write(f"{now_iso()} {message}\n")
    except (OSError, ImportError, KeyError):
        pass


_scan_threats_module = None


def _scan_threats():
    """Load scripts/scan-threats.py by path.

    Same loader shape as lib/transcript.py's -- the filename is hyphenated, so
    it is not importable as a module name, and there is exactly one
    THREAT_PATTERNS table in this project on purpose.
    """
    global _scan_threats_module
    if _scan_threats_module is None:
        path = Path(__file__).resolve().parent / "scan-threats.py"
        spec = importlib.util.spec_from_file_location("sl_scan_threats_inject", path)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load scan-threats.py from {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _scan_threats_module = module
    return _scan_threats_module


def _gate_line(text: str) -> "tuple[str, str | None]":
    """Return (safe_text, blocked_category).

    A line that trips a threat pattern is replaced wholesale, not edited: a
    partial rewrite of an injection attempt can still carry the instruction,
    and the categories here (prompt_injection, credentials, private keys) are
    ones where no part of the line is worth keeping.
    """
    if not text.strip():
        return text, None
    try:
        # "relaxed" skips exactly {encoded_payloads, shell_injection_in_content}
        # (scan-threats.py:88) and keeps prompt_injection plus every credential
        # category -- the ones that matter for text entering a model's context.
        #
        # Measured against the real store 2026-07-30: "strict" blocked 5 of 137
        # MEMORY.md lines and all five were false positives. The pattern is
        # `(?i)`.*(?:curl|wget|nc|bash|sh|python).*` -- a backtick followed
        # anywhere by those substrings, which "occurre[nc]es", "concurrency" and
        # "[sh]lex" all satisfy. It is written for content a shell may execute;
        # this text is injected for a model to READ and is never executed, so
        # here it only destroys real lessons about shell quoting.
        #
        # Re-derive:
        #   python3 - <<'EOF'
        #   import importlib.util, pathlib
        #   s=importlib.util.spec_from_file_location("st","scripts/scan-threats.py")
        #   st=importlib.util.module_from_spec(s); s.loader.exec_module(st)
        #   mem=(pathlib.Path.home()/".local/share/agent-learning/memory/MEMORY.md")
        #   for l in mem.read_text().splitlines():
        #       for scope in ("strict","relaxed"):
        #           if st.scan_for_threats(l, scope=scope): print(scope, l[:90])
        #   EOF
        findings = _scan_threats().scan_for_threats(text, scope="relaxed")
    except (ImportError, OSError, AttributeError):
        # A threat table we cannot load must not silently become "no threats".
        # Fail closed: block the line and say why.
        return "[BLOCKED: threat scanner unavailable]", "scanner_unavailable"
    if not findings:
        return text, None
    category = findings[0].get("category", "unknown")
    return f"[BLOCKED: {category}]", category


def gate_for_injection(text: str) -> "tuple[str, list[str]]":
    """Gate text line by line, returning (safe_text, blocked_categories).

    Hermes' pattern, both halves: the blocked marker goes into the INJECTED
    text and the raw entry stays on disk untouched, so the user can still see
    and remove it (tools/memory_tool.py load_from_disk / snapshot sanitisation).
    Dropping the line instead would hide the attack; rewriting the file would
    destroy the evidence.

    Line granularity suits MEMORY.md, which is one lesson per line -- one
    poisoned entry costs that entry, not the whole block.
    """
    blocked: list[str] = []
    safe_lines: list[str] = []
    for line in text.splitlines():
        safe, category = _gate_line(line)
        if category:
            blocked.append(category)
        safe_lines.append(safe)
    return "\n".join(safe_lines), blocked


def _inject_budget() -> int:
    raw = os.environ.get("SL_MEMORY_INJECT_BUDGET", "")
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_MEMORY_INJECT_BUDGET
    return value if value > 0 else DEFAULT_MEMORY_INJECT_BUDGET


def read_memory(memory_dir: Path) -> str:
    """Return MEMORY.md in full. Never truncates.

    Over-budget is reported to persist-failures.log and still injected --
    dropping a lesson silently is worse than injecting a large block, and the
    reviewer cannot consolidate a file it is never told is oversized.
    """
    memory_file = memory_dir / "MEMORY.md"
    if not memory_file.is_file():
        return ""
    content = memory_file.read_text(encoding="utf-8", errors="replace")
    budget = _inject_budget()
    size = len(content.encode("utf-8"))
    if size > budget:
        _log_advisory(
            f"{memory_file} is {size} bytes, over the {budget}-byte injection "
            "budget -- injected in full anyway (never truncated). Consolidate "
            "overlapping entries to bring it back under budget."
        )
    content, blocked = gate_for_injection(content)
    if blocked:
        _log_advisory(
            f"{memory_file}: BLOCKED {len(blocked)} memory line(s) from the "
            f"injected block (categories: {', '.join(sorted(set(blocked)))}). "
            "The raw lines are UNCHANGED on disk -- read them and delete them "
            "if they are hostile. Injected content reaches every future "
            "session, so a match is gated rather than trusted."
        )
    return content.strip()


def read_skill_description(skill_md: Path) -> str:
    """Extract `description:` from simple YAML frontmatter without a YAML lib."""
    try:
        lines = skill_md.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    if not lines or lines[0].strip() != "---":
        return ""
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if line.startswith("description:"):
            return line[len("description:"):].strip()
    return ""


def list_skills(skills_dir: Path) -> list:
    entries = []
    if not skills_dir.is_dir():
        return entries
    for child in sorted(skills_dir.iterdir()):
        if child.name.startswith(".") or not child.is_dir():
            continue
        skill_md = skill_layout.skill_md_path(skills_dir, child.name)
        if skill_md.is_file():
            # The description is injected verbatim, so it is gated exactly like
            # a memory line. The skill NAME is kept either way: a name is not a
            # sentence and cannot carry an instruction, and dropping the row
            # entirely would hide the poisoned skill instead of flagging it.
            description, blocked = gate_for_injection(read_skill_description(skill_md))
            if blocked:
                _log_advisory(
                    f"{skill_md}: BLOCKED this skill's description from the "
                    f"injected block (categories: {', '.join(sorted(set(blocked)))}). "
                    "The skill is still listed by name. The file is UNCHANGED "
                    "on disk -- read it and delete the skill if it is hostile."
                )
            entries.append((child.name, description))
    return entries


def build_block(memory_dir: Path, skills_dir: Path) -> str:
    parts = [BEGIN, "## Learned context (auto-managed — do not edit inside markers)", ""]
    memory = read_memory(memory_dir)
    if memory:
        parts += ["### Memory", memory, ""]
    skills = list_skills(skills_dir)
    if skills:
        parts.append("### Learned skills")
        for name, desc in skills:
            parts.append("- **{}**: {}".format(name, desc or "(no description)"))
        parts.append("")
    if not memory and not skills:
        parts += ["_No learned context yet._", ""]
    parts.append(END)
    return "\n".join(parts)


def inject(target: Path, block: str) -> None:
    if target.is_file():
        content = target.read_text(encoding="utf-8", errors="replace")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        content = ""

    if BEGIN in content and END in content:
        before = content.split(BEGIN, 1)[0]
        after = content.split(END, 1)[1]
        new_content = before + block + after
    else:
        sep = "" if (content == "" or content.endswith("\n\n")) else ("\n" if content.endswith("\n") else "\n\n")
        new_content = content + sep + block + "\n"

    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(new_content, encoding="utf-8")
    os.replace(str(tmp), str(target))


def _default_dir(env_var: str, paths_key: str) -> Path:
    """Resolve one store directory: explicit env var wins, else lib/paths.py.

    C2-shaped bug fixed here: this used to fall back to a hardcoded
    ~/.claude/... literal instead of consulting the single path resolver,
    which is wrong on any install that isn't Claude Code -- Copilot CLI and
    VS Code Copilot Chat have no ~/.claude at all.
    """
    value = os.environ.get(env_var)
    if value:
        return Path(value)
    return paths.resolve_all()[paths_key]


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: inject-agents-md.py <target-agents-md-path>", file=sys.stderr)
        return 1
    memory_dir = _default_dir("SL_MEMORY_DIR", "memory")
    skills_dir = _default_dir("SL_SKILLS_DIR", "skills")
    target = Path(sys.argv[1])
    try:
        inject(target, build_block(memory_dir, skills_dir))
    except OSError as exc:
        print("inject-agents-md: cannot write {}: {}".format(target, exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
