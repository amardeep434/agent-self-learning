Review the conversation context above and consider saving to memory if appropriate.

Focus on two areas:

1. **User persona and preferences** -- Has the user revealed things about
   themselves worth remembering? Their name, role, timezone, team, communication
   preferences, tool preferences, or personal workflow habits.

2. **Behavioral expectations** -- Has the user expressed expectations about how
   you should behave? Their work style, response format preferences, level of
   detail they want, or things they explicitly asked you to stop doing or
   start doing.

## How to Write

### MEMORY.md (agent operational notes)

Location: ~/.claude/memory/MEMORY.md
Character limit: 2200 characters maximum
Entry separator: each entry on its own line

Content types for MEMORY.md:
- Project facts: "Project uses PostgreSQL 16 with RLS enabled on all tables"
- Corrections: "User corrected: always use ErrorMapper.toUserMessage(), never e.message"
- Tool quirks: "gradlew assembleDebug requires JDK 17, not 21"
- Workflow facts: "CI pipeline requires REQUIRE_DB=true for integration tests"

### USER.md (user profile)

Location: ~/.claude/memory/USER.md
Character limit: 1375 characters maximum
Entry separator: each entry on its own line

Content types for USER.md:
- Identity: "Name: Amardeep. Senior Android developer."
- Communication style: "Prefers concise, direct responses. Gets frustrated with verbosity."
- Tool preferences: "Kotlin-first. Material 3. Jetpack Compose."
- Working patterns: "Works in IST timezone. Prefers feature branches."

## Rules

- Maximum 3 memory writes per review cycle
- Each entry: one line, under 120 characters, factual and actionable
- Read existing files FIRST -- do not duplicate existing entries
- If an entry is outdated, REPLACE it (edit the line) rather than add + remove
- Never save: secrets, tokens, API keys, passwords, credentials
- Never save: personal data beyond name/role/timezone
- If at character limit, remove the least relevant entry before adding
- If nothing is worth saving, say "Nothing to save." and stop
- "Nothing to save." is a real option but should not be the default for
  sessions that had meaningful interaction

## Procedure

1. Read ~/.claude/memory/MEMORY.md (current agent notes)
2. Read ~/.claude/memory/USER.md (current user profile)
3. Review the conversation digest below
4. Identify 0-3 items worth saving (be selective -- skip if nothing stands out)
5. Write updates using the Edit tool (or create file if it does not exist)
6. Log each action with a one-line summary

## Entry Format

MEMORY.md entries (one per line):
```
Entry text here (concise, factual, actionable)
```

USER.md entries:
```
Name: <name>. <role>. <key facts>.
Communication: <style>. <preferences>. <timezone>.
```

## DO NOT Save

- Task progress or session outcomes (use session search for these)
- One-off commands that were run
- Environment-dependent failures (missing binaries, network errors)
- Secrets, tokens, API keys, passwords
- Information that is already in the project's CLAUDE.md
