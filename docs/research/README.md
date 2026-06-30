# Hermes Agent Self-Learning Research

Deep analysis of NousResearch's Hermes Agent self-learning system, validated against actual source code, with a comprehensive implementation guide for adapting it to Claude Code.

**Date:** 2026-06-30
**Source:** https://github.com/nousresearch/hermes-agent (+ 3 companion repos)

## Document Index

### Research Documents

| # | File | Lines | Content |
|---|------|-------|---------|
| 01 | `01-architecture-and-structure.md` | 725 | Repository structure, file inventory, directory layout |
| 02 | `02-self-learning-mechanisms.md` | 786 | 8 self-learning mechanisms: Background Review, Skill Library, Memory System, Curator, Training Pipeline, Learning Graph, External Memory Providers, /learn Command |
| 03 | `03-training-and-finetuning.md` | 965 | Training pipeline: batch_runner, trajectory_compressor, external importers, DSPy GEPA |
| 04 | `04-prompts-and-reflection.md` | 1162 | Verbatim review prompts, fork architecture, tool whitelist, digest history |
| 05 | `05-skill-lifecycle-and-curator.md` | 1322 | Skill provenance, usage telemetry, CURATOR_REVIEW_PROMPT, guard chain, archive/restore |
| 06 | `06-missing-areas-research.md` | 626 | 8 additional subsystems: Session Search FTS5, SOUL.md, Skill Preprocessing, System Prompt Assembly, Context Engine, Memory Provider, User Profile, Skill Hub |

### Validation Documents

| File | Validates | Findings |
|------|-----------|----------|
| `01-validation-notes.md` | Doc 01 | File counts, line counts, directory structure accuracy |
| `02-validation-notes.md` | Doc 02 | 50 findings: 42 VERIFIED, 8 INACCURATE (minor) |
| `03-validation-notes.md` | Doc 03 | Original validation (4 fabricated code snippets identified) |
| `03-corrections.md` | Doc 03 | 13 corrections with verbatim actual source code |
| `05-validation-notes.md` | Doc 05 | 50 findings: 47 VERIFIED, 3 PARTIALLY CORRECT, 0 FABRICATED |
| `validation-03-training.md` | Doc 03 | Training systems validation (all major claims verified) |
| `validation-04-prompts.md` | Doc 04 | Prompts validation (all 12 claims VERIFIED EXACT) |

### Implementation Guide

| File | Lines | Content |
|------|-------|---------|
| `07-implementation-guide-for-claude-code.md` | ~10,000 | Complete implementation guide: 5 primary subsystems, shell scripts, SQL schemas, adapted prompts, 5-phase roadmap, configuration reference, file layout |

## Key Findings

### Hermes Self-Learning Architecture (8 Mechanisms)

1. **Background Review** — Post-turn daemon forks agent every 10 turns with tool whitelist [memory, skill_manage]. Three review prompts (memory, skill, combined). 26% cost reduction via cached system prompt.

2. **Skill Library** — File-backed SKILL.md files with support dirs (references/, templates/, scripts/). Usage telemetry (.usage.json). Three lifecycle states: active -> stale (30d) -> archived (90d).

3. **Memory System** — Two bounded stores: MEMORY.md (2200 chars) + USER.md (1375 chars). Frozen snapshot pattern (read once at session start, writes update disk only). Security scanning via threat_patterns.py.

4. **Curator** — Periodic maintenance every 7 days. Deterministic lifecycle transitions + optional LLM consolidation of narrow skills into class-level umbrellas.

5. **Session Search** — SQLite FTS5 full-text search over session history. Four shapes: DISCOVERY, SCROLL, READ, BROWSE. Lineage deduplication.

6. **Training Pipeline** — Batch processing, trajectory compression, external session importers, DSPy-based optimization.

7. **External Memory Providers** — Plugin architecture for external memory backends.

8. **/learn Command** — User-triggered skill distillation from current session.

### Source Repos Analyzed

- `/tmp/hermes-agent-research/` — Main Hermes Agent repository
- `/tmp/hermes-agent-evolution/` — Skill evolution and training data generation
- `/tmp/tinker-atropos/` — LoRA fine-tuning framework
- `/tmp/hermes-compression-eval/` — Compression quality evaluation
