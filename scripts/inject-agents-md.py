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

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import paths  # noqa: E402

BEGIN = "<!-- BEGIN self-learning:managed -->"
END = "<!-- END self-learning:managed -->"
MAX_MEMORY_CHARS = 2200


def read_memory(memory_dir: Path) -> str:
    memory_file = memory_dir / "MEMORY.md"
    if not memory_file.is_file():
        return ""
    return memory_file.read_text(encoding="utf-8", errors="replace")[:MAX_MEMORY_CHARS].strip()


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
        skill_md = child / "SKILL.md"
        if skill_md.is_file():
            entries.append((child.name, read_skill_description(skill_md)))
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
