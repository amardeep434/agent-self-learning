# Self-Learning Protocol

## Background Review (Mid-Session)

After completing a user request (not mid-task), check if the file
`~/.claude/state/review_signal.json` exists. If it does:

1. Read the signal file to determine review type (memory, skills, or both)
2. Delete the signal file immediately (prevents re-triggering)
3. Spawn a review subagent using the Agent tool with the appropriate review
   prompt from `~/.claude/scripts/review-prompts/`
4. The subagent has a budget of 16 tool uses maximum
5. After the subagent completes, continue with the user's work
6. Do NOT announce the review to the user unless you created something notable

If the signal file does not exist, do nothing -- proceed normally.

### Turn Counting Awareness

A PostToolUse hook (`turn-counter.sh`) increments a counter after every tool
use. When the counter reaches the review threshold (default: 10), the hook
writes a review signal file. You do not need to count turns yourself -- the
hook handles this automatically.

The counter resets after each review cycle and at session end.

### When to Spawn Review Subagent

Spawn the review subagent when ALL of these conditions are true:
- The review signal file (`~/.claude/state/review_signal.json`) exists
- You have just completed the user's current request (not mid-task)
- No review has run in the last 60 seconds

Do NOT spawn a review subagent:
- In the middle of a multi-step task
- When the user is waiting for an answer
- More than once per 60-second window

### Review Subagent Prompt

When spawning the review subagent via the Agent tool, use the combined review
prompt. The subagent should:

1. Read `~/.claude/memory/MEMORY.md` and `~/.claude/memory/USER.md`
2. Scan `~/.claude/learned-skills/` for existing skills
3. Review the conversation context for:
   - User corrections or preferences (save to MEMORY.md or USER.md)
   - Reusable patterns or workflows (save to learned-skills/)
   - Outdated skills that need patching
4. Write updates to disk (memory files, skill files)
5. Respect budget limits: max 3 memory writes, max 2 skill operations

### Memory Review Behavior

Memory is split into two bounded stores:
- **MEMORY.md** (`~/.claude/memory/MEMORY.md`, max 2200 chars): Agent operational
  notes -- project facts, corrections, tool quirks, workflow conventions.
- **USER.md** (`~/.claude/memory/USER.md`, max 1375 chars): User profile --
  name, role, communication style, tool preferences, timezone.

Rules:
- Each entry: one line, under 120 characters
- Read existing files first -- do not duplicate
- Replace outdated entries rather than add + remove
- Never save secrets, tokens, API keys, or passwords
- If at character limit, remove least relevant entry before adding

### Skill Review Behavior

Skills are stored in `~/.claude/learned-skills/<skill-name>/SKILL.md`.

Preference order for skill updates:
1. UPDATE an existing learned skill that was in play this session
2. UPDATE an existing umbrella skill in the same domain
3. ADD a support file (references/, templates/, scripts/) under an umbrella
4. CREATE a new class-level umbrella skill (last resort)

Rules:
- Prefer broad class-level skills over narrow one-off skills
- Skill names: lowercase-kebab-case, max 64 characters
- Descriptions: one sentence, max 60 characters, ends with period
- Author field: always "claude-code-review" (never environment-derived)
- When the user corrects how you handle a task, update the skill that governs
  that task -- memory alone is not enough

### Session Search

Past sessions are indexed in a SQLite FTS5 database at
`~/.claude/sessions/search.db`. When you need to recall information from a
previous session, use the session search tool with one of four query shapes:
- **discover**: Full-text search across all sessions (BM25 ranked)
- **scroll**: Navigate within a session around an anchor message
- **read**: Read full session (first 20 + last 10 messages for large sessions)
- **browse**: List recent sessions chronologically

## Context Compression Guidance

When your context is being compressed:
1. Ensure the session's goal and initial user request survive compression
2. Ensure the most recent tool results and decisions survive compression
3. If you have unwritten learnings (patterns observed, corrections received),
   write them to memory BEFORE compression discards them
