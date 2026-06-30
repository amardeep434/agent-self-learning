Review the conversation context above and update the skill library. Be
ACTIVE -- most productive sessions produce at least one skill update, even
if small. A pass that does nothing is a missed learning opportunity, not a
neutral outcome.

Target shape of the library: CLASS-LEVEL skills, each with a rich SKILL.md
and optional support directories (references/, templates/, scripts/) for
session-specific detail. Not a long flat list of narrow one-session-one-skill
entries. This shapes HOW you update, not WHETHER you update.

## Signals to Look For

Any one of these warrants action:

- **User corrected your style, tone, format, or verbosity.** Frustration
  signals like "stop doing X", "this is too verbose", "don't format like
  this", "why are you explaining", "just give me the answer", or an explicit
  "remember this" are FIRST-CLASS skill signals, not just memory signals.
  Update the relevant skill(s) to embed the preference so the next session
  starts already knowing.

- **User corrected your workflow, approach, or sequence of steps.** Encode
  the correction as a pitfall or explicit step in the skill that governs
  that class of task.

- **Non-trivial technique, fix, workaround, debugging path, or tool-usage
  pattern emerged** that a future session would benefit from. Capture it.

- **A skill that was loaded or consulted this session turned out to be
  wrong, missing a step, or outdated.** Patch it NOW.

## Preference Order

Prefer the earliest action that fits, but do pick one when a signal fired:

1. **UPDATE AN EXISTING LEARNED SKILL.** Look back through the conversation
   for skills that were invoked or read. If any of them covers the territory
   of the new learning, PATCH that one first. It is the skill that was in
   play, so it is the right one to extend.

2. **UPDATE AN EXISTING UMBRELLA.** Scan ~/.claude/learned-skills/ for a
   class-level skill that covers the domain. If one exists, patch it -- add
   a subsection, a pitfall, or broaden a trigger condition.

3. **ADD A SUPPORT FILE under an existing umbrella.** Skills can have
   three kinds of support files -- use the right directory:
   - `references/<topic>.md` -- session-specific detail (error transcripts,
     reproduction recipes, provider quirks) AND condensed knowledge banks
     (quoted research, API docs excerpts, domain notes). Write concisely.
   - `templates/<name>.<ext>` -- starter files meant to be copied and
     modified (boilerplate configs, scaffolding, known-good examples).
   - `scripts/<name>.<ext>` -- re-runnable actions the skill can invoke
     (verification scripts, fixture generators, probes).
   Add support files by creating files in the skill's subdirectory. Update
   SKILL.md with a one-line pointer to the new file.

4. **CREATE A NEW CLASS-LEVEL UMBRELLA SKILL** when no existing skill covers
   the class. The name MUST be at the class level. The name MUST NOT be a
   specific PR number, error string, feature codename, library-alone name,
   or "fix-X / debug-Y / audit-Z-today" session artifact. If the proposed
   name only makes sense for today's task, it is wrong -- fall back to (1),
   (2), or (3).

## User-Preference Embedding

When the user expressed a style/format/workflow preference, the update
belongs in the SKILL.md body, not just in memory. Memory captures "who the
user is"; skills capture "how to do this class of task for this user". When
they complain about how you handled a task, the skill that governs that task
needs to carry the lesson.

## Skill File Format

Location: ~/.claude/learned-skills/<skill-name>/SKILL.md

```yaml
---
name: lowercase-kebab-case (max 64 chars)
description: One sentence, max 60 characters, ends with period.
version: 0.1.0
author: claude-code-review
tags: [Relevant, Tags]
category: coding|workflow|debugging|project|tooling
---
```

Body section order:
1. `# <Human Title>` -- 2-3 sentence intro
2. `## When to Use` -- bullet list of trigger phrases
3. `## Prerequisites` -- env vars, install steps
4. `## Procedure` -- numbered steps with exact commands
5. `## Pitfalls` -- known limits, things that look broken but are not
6. `## Verification` -- single check that proves the skill worked

Quality: ~100-200 lines. Prefer exact commands and code from the session.
Do not write router/index skills that only point at other skills.

## Usage Telemetry

Also create/update the usage sidecar:

Location: ~/.claude/learned-skills/.usage.json (global file)

Add entry for the skill:
```json
{
  "<skill-name>": {
    "use_count": 0,
    "view_count": 0,
    "patch_count": 1,
    "last_used_at": null,
    "last_patched_at": "<ISO datetime>",
    "created_at": "<ISO datetime>",
    "state": "active",
    "created_by": "agent",
    "pinned": false
  }
}
```

## DO NOT Capture

- Environment-dependent failures (missing binaries, unconfigured credentials)
- Negative claims about tools ("tool X does not work")
- Session-specific transient errors that resolved
- One-off task narratives
- Information that belongs in MEMORY.md (project facts, user preferences)

Exception: if a tool failed because of setup state, capture the FIX (install
command, config step, env var to set) under an existing setup skill -- never
"this tool does not work" as a standalone constraint.

## Existing Skills to Consider

Check ~/.claude/learned-skills/ before creating new skills. If you notice
two existing skills that overlap, note it in your reply -- the Curator
handles consolidation at scale.

## Budget

- Maximum 2 skill operations per review cycle (create or update)
- Maximum 16 total tool uses
- Be efficient: read existing state first, then act

## Escape Hatch

"Nothing to save." is a real option but should NOT be the default. If the
session ran smoothly with no corrections and produced no new technique, just
say "Nothing to save." and stop. Otherwise, act.
