Review the conversation context above and update two things:

**Memory**: who the user is. Did the user reveal persona, desires,
preferences, personal details, or expectations about how you should behave?
Save facts about the user and durable preferences.

**Skills**: how to do this class of task. Be ACTIVE -- most sessions produce
at least one skill update. A pass that does nothing is a missed learning
opportunity, not a neutral outcome.

## Memory Review

### MEMORY.md (agent notes, ~/.claude/memory/MEMORY.md, max 2200 chars)
Save: project facts, corrections, tool quirks, workflow conventions.
Format: one entry per line, under 120 chars, factual and actionable.

### USER.md (user profile, ~/.claude/memory/USER.md, max 1375 chars)
Save: name, role, communication style, tool preferences, timezone.
Format: one entry per line, under 120 chars.

## Skill Review

Target shape: CLASS-LEVEL skills with rich SKILL.md files. Not a flat list
of narrow one-session-one-skill entries.

Signals that warrant a skill update (any one is enough):

- User corrected your style, tone, format, verbosity, or approach.
  Frustration is a FIRST-CLASS skill signal. "stop doing X", "don't format
  like this" -- embed the lesson in the skill that governs that task so the
  next session starts fixed.

- Non-trivial technique, fix, workaround, or debugging path emerged.

- A skill that was loaded or consulted turned out wrong, missing, or
  outdated -- patch it now.

Preference order for skills -- pick the earliest that fits:
1. UPDATE an existing learned skill that was in play this session
2. UPDATE an existing umbrella skill (scan ~/.claude/learned-skills/)
3. ADD A SUPPORT FILE (references/, templates/, scripts/) under an umbrella
4. CREATE A NEW CLASS-LEVEL UMBRELLA (last resort; name at the class level,
   never a PR number, error string, or session artifact)

User-preference embedding: when the user complains about how you handled a
task, update the skill that governs that task -- memory alone is not enough.
Memory says "who the user is"; skills say "how to do this class of task for
this user". Both should carry user-preference lessons when relevant.

## Skill Format

Location: ~/.claude/learned-skills/<skill-name>/SKILL.md
Frontmatter: name (kebab, max 64), description (max 60 chars, period),
version 0.1.0, author claude-code-review, tags, category.
Body: Title, When to Use, Prerequisites, Procedure, Pitfalls, Verification.
Size: ~100-200 lines.

## Do NOT Capture as Skills

- Environment-dependent failures (missing binaries, unconfigured credentials)
- Negative claims about tools ("X does not work") -- these harden into refusals
- Session-specific transient errors that resolved
- One-off task narratives

Exception: capture the FIX for setup failures, never "tool does not work."

## Do NOT Save as Memory

- Task progress or session outcomes
- One-off commands that were run
- Environment-dependent failures
- Secrets, tokens, API keys, passwords
- Information already in the project's CLAUDE.md

## Budget

- Maximum 3 memory writes (MEMORY.md + USER.md combined)
- Maximum 2 skill operations (create or update)
- Maximum 16 total tool uses

## Procedure

1. Read existing memory files:
   - ~/.claude/memory/MEMORY.md
   - ~/.claude/memory/USER.md
2. Scan existing skills:
   - ls ~/.claude/learned-skills/
3. Review the conversation digest below
4. Identify the highest-value items (be selective)
5. Execute writes (memory updates first, then skill operations)
6. Log each action

Prioritize by value:
1. User corrections (highest -- prevents repeating mistakes)
2. Reusable patterns/workflows (high -- saves future time)
3. Project facts (medium -- provides context)
4. User preferences (medium -- improves interaction quality)
5. One-off techniques (low -- skip unless exceptionally useful)

Act on whichever dimension has real signal. If genuinely nothing stands out
on either, say "Nothing to save." and stop -- but do not reach for that
conclusion as a default.
