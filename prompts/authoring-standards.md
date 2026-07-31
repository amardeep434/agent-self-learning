# Skill Authoring Standards

These rules govern how the Background Review subagent and the `/learn` command
write skills. They are enforced in the review prompts and by the Curator.
Adapted from Hermes Agent's `_AUTHORING_STANDARDS` (96 lines of strict rules).

---

## 1. Naming Rules

| Rule | Constraint | Example (Good) | Example (Bad) |
|------|-----------|----------------|---------------|
| Format | `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` (matches `scripts/lib/proposal_schema.py`'s `SKILL_NAME_RE`; no dots — a prior version of this table used a dot-inclusive pattern that contradicted the enforced schema) | `kotlin-testing-patterns` | `Kotlin Testing` |
| Length | Max 64 characters | `android-compose-navigation` | `how-to-set-up-jetpack-compose-navigation-with-material-3-bottom-bar-in-android-15` |
| Class-level | Name must describe a class of tasks, not a specific task | `gradle-build-debugging` | `fix-pr-1234-build-failure` |
| No session artifacts | Must make sense outside the current session | `error-handling-patterns` | `debug-login-today` |
| No library-alone | Must include class framing | `supabase-rls-patterns` | `supabase` |

## 2. Description Rules

The description is the single most critical field. It is used in the skill
index that gets loaded into the system prompt. The index truncates at 60
characters -- anything past char 60 is silently cut and never helps routing.

**Hard constraint: max 60 characters, one sentence, ends with period.**

```
Good (49 chars): "Structured concurrency patterns in Kotlin coroutines."
Good (58 chars): "Debug Gradle build failures with dependency conflict fixes."
Bad (123 chars): "A comprehensive skill that lets the agent debug various types
                  of Gradle build failures using multiple strategies."
```

**The review agent must COUNT characters before saving.** If the description
exceeds 60, it must be shortened before writing.

**Banned words:** "powerful", "comprehensive", "seamless", "advanced", "robust".
These are filler that wastes the character budget.

## 3. Class-Level Naming Requirements

Skill names must describe a CLASS of tasks, not a specific instance:

### Acceptable (class-level)
- `kotlin-testing-patterns` -- covers a family of testing techniques
- `gradle-build-debugging` -- covers a category of build issues
- `git-rebase-patterns` -- covers a class of git operations
- `android-compose-navigation` -- covers navigation patterns broadly

### Rejected (too narrow or session-specific)
- `fix-pr-1234-build-failure` -- specific PR number
- `debug-login-today` -- session artifact
- `supabase` -- library-alone, no class framing
- `mock-datetime-in-pytest` -- single narrow technique
- `audit-z-today` -- ephemeral task name

**Test:** If the proposed name only makes sense for today's task, it is wrong.
A skill name should be meaningful to someone who was not in the session where
it was created.

## 4. Frontmatter Schema

```yaml
---
name: lowercase-kebab-case (max 64 chars)
description: One sentence, max 60 characters, ends with period.
version: 0.1.0
author: agent-review
tags: [tag1, tag2]
category: coding|workflow|debugging|project|tooling
created: 2026-01-15T10:30:00Z
updated: 2026-01-15T10:30:00Z
state: active
provenance: agent-created
---
```

| Field | Type | Constraints | Required |
|-------|------|------------|----------|
| `name` | string | lowercase-kebab-case, max 64 chars | yes |
| `description` | string | max 60 chars, one sentence, ends with period | yes |
| `author` | string | always `agent-review` for agent-created | yes |
| `category` | enum | `coding`, `workflow`, `debugging`, `project`, `tooling` | yes |
| `tags` | string[] | lowercase, max 8 tags, max 24 chars each | no |
| `created` | ISO 8601 | set once at creation | yes |
| `updated` | ISO 8601 | set on every modification | yes |
| `state` | enum | `active`, `stale`, `archived` | yes |
| `provenance` | enum | `bundled`, `hub-installed`, `agent-created` | yes |
| `version` | integer | increment on each update | yes |

## 5. Body Section Order

The body must follow this section order (omit a section only if it genuinely
has no content):

1. `# <Human Title>` -- 2-3 sentence intro paragraph
2. `## When to Use` -- bullet list of trigger phrases/conditions
3. `## Prerequisites` -- env vars, install steps, dependencies
4. `## Quick Reference` -- concise command/pattern summary (optional)
5. `## Procedure` -- numbered steps with exact commands
6. `## Pitfalls` -- known limits, common mistakes, things that look broken
7. `## Verification` -- single check that proves the skill worked

**Target size:** ~100-200 lines. No router/index skills that only point at
other skills. Each skill must contain actionable content.

## 6. Content Quality Rules

1. **Prefer exact commands and code from the session.** Do not invent flags,
   paths, or APIs. If you did not see it in the source, do not write it.

2. **Reference tools by the harness's own tool name where one exists**
   (Claude Code: "Read", "Grep", "Edit", "Bash"). Skills are injected into
   Claude Code, Copilot CLI and VS Code Copilot Chat sessions alike, and the
   tool names differ, so prefer harness-neutral phrasing -- "read the file",
   "search the tree" -- over shell commands like cat/head/tail/grep/sed.

3. **Keep it tight and scannable.** ~100 lines for a simple skill, ~200 for
   a complex one. Do not re-paste upstream documentation.

4. **Do not write router/index/hub skills** that only point at other skills.
   Each skill must contain actionable content.

5. **Larger scripts belong in `scripts/`.** If a procedure requires a
   non-trivial script (>20 lines), save it as `scripts/<name>.sh` and
   reference it from SKILL.md by relative path. Do not inline large scripts
   for the agent to re-type each session.

## 7. Support File Taxonomy

Skills can have four types of support directories. The taxonomy is strict:

| Directory | Content | Examples |
|-----------|---------|---------|
| `references/` | Knowledge banks, API doc excerpts, error transcripts, domain notes, reproduction recipes, provider quirks | `api-quirks.md`, `error-recipes.md`, `coroutine-cheatsheet.md` |
| `templates/` | Starter files meant to be copied and modified (boilerplate, scaffolds, known-good examples) | `viewmodel-scaffold.kt`, `docker-compose.template.yml` |
| `scripts/` | Re-runnable actions the skill can invoke (verification scripts, fixture generators, probes) | `verify-rls.sh`, `generate-fixtures.py` |
| `assets/` | Static assets (images, diagrams, screenshots) | `architecture-diagram.png` |

**Rules:**
- Support files must be referenced from SKILL.md with a one-line pointer
- Each support file is bounded at 100,000 chars (references) or 1 MiB (others)
- Do not duplicate content between SKILL.md and support files

## 8. Privacy Protection

The `author` field must always be the literal string `"agent-review"`. It is
harness-neutral on purpose: the same store is written by reviewers running under
Claude Code, Copilot CLI and VS Code Copilot Chat. The legacy literal
`"claude-code-review"` remains valid on read for one release, so skills authored
before this rename keep validating; do not emit it in new skills.

**NEVER derive the author from:**
- OS/login username
- Git config (`user.name`, `user.email`)
- Environment variables
- Any probed identity

Skills may be shared or published. An environment-derived name is a privacy
leak the user never opted into.

## 9. Usage Telemetry

Every skill has a telemetry entry in the global `.usage.json` file:

```json
{
  "<skill-name>": {
    "use_count": 0,
    "view_count": 0,
    "patch_count": 1,
    "last_used_at": null,
    "last_patched_at": "2026-01-15T10:30:00Z",
    "created_at": "2026-01-15T10:30:00Z",
    "state": "active",
    "created_by": "agent",
    "pinned": false
  }
}
```

- `use_count`: **reserved, always 0 today.** Nothing increments it. Measured
  2026-07-30: all 50 tracked skills read 0, and
  `grep -rn "use_count" scripts/ | grep -E "\+= *1|increment"` returns nothing.
  It is initialised by `persist-proposal.py` and read by `skill-lifecycle.py`,
  but no harness reports skill invocation to us, so nothing ever raises it.
- `view_count`: **reserved, never written at all** -- absent from every record
  in the live `.usage.json`, not merely zero.
- `patch_count`: incremented when the skill is updated
- `created_by`: `"agent"` (background review), `"user"` (/learn command),
  `"hub"` (installed from registry)
