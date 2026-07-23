export const meta = {
  name: 'execute-copilot-coach-plan',
  description: 'Execute the 2026-07-22 Copilot port + Coach integration plan task-by-task with per-task model routing, journaled progress, and rate-limit-proof resume',
  whenToUse: 'Run to implement docs/superpowers/plans/2026-07-22-copilot-port-and-coach-integration.md. Pass {startTask: N} to begin at task N; combine with resumeFromRunId after an interruption.',
  phases: [
    { title: 'Phase A: Claude Code fixes' },
    { title: 'Phase B: AGENTS.md injection' },
    { title: 'Phase C: Copilot CLI adapter', model: 'opus' },
    { title: 'Phase D: Coach Route A' },
    { title: 'Phase E: Coach fork Route B', model: 'opus' },
    { title: 'Phase F: Hardening, uninstall, Windows, docs' },
    { title: 'Final checks' },
  ],
}

// ---------------------------------------------------------------------------
// Task table. Model routing rationale:
//   sonnet — mechanical, single-file, fully-specified-by-plan tasks
//   opus   — multi-file edits, subtle semantics (schema fixes, dedupe logic),
//            TypeScript patch requiring reading unfamiliar upstream code, and
//            the hard-stop verification gates (judgment about STOP vs PASS)
// ---------------------------------------------------------------------------
const PLAN = 'docs/superpowers/plans/2026-07-22-copilot-port-and-coach-integration.md'
const PROGRESS = 'docs/execution-progress.jsonl'

const TASKS = [
  { n: 1,  title: 'Hook stdin-JSON parser library',            model: 'sonnet', phase: 'Phase A: Claude Code fixes' },
  { n: 2,  title: 'Shared config file + loader',               model: 'sonnet', phase: 'Phase A: Claude Code fixes' },
  { n: 3,  title: 'Fix turn-counter.sh',                       model: 'sonnet', phase: 'Phase A: Claude Code fixes' },
  { n: 4,  title: 'Fix session-review.sh + settings schema',   model: 'opus',   phase: 'Phase A: Claude Code fixes' },
  { n: 5,  title: 'inject-agents-md.py',                       model: 'sonnet', phase: 'Phase B: AGENTS.md injection' },
  { n: 6,  title: 'Copilot hook template + review script',     model: 'sonnet', phase: 'Phase C: Copilot CLI adapter' },
  { n: 7,  title: 'Extend install.sh for Copilot adapter',     model: 'sonnet', phase: 'Phase C: Copilot CLI adapter' },
  { n: 8,  title: 'GATE: live Claude Code hook verification',  model: 'opus',   phase: 'Phase C: Copilot CLI adapter', gate: true },
  { n: 9,  title: 'GATE: live Copilot CLI verification',       model: 'opus',   phase: 'Phase C: Copilot CLI adapter', gate: true },
  { n: 10, title: 'Vendor Coach rule files',                   model: 'sonnet', phase: 'Phase D: Coach Route A' },
  { n: 11, title: 'Route A rule evaluator',                    model: 'opus',   phase: 'Phase D: Coach Route A' },
  { n: 12, title: 'Signals merge + Route B reader + wiring',   model: 'opus',   phase: 'Phase D: Coach Route A' },
  { n: 13, title: 'Create and patch the Coach fork',           model: 'opus',   phase: 'Phase E: Coach fork Route B', gate: true },
  { n: 14, title: 'Fork maintenance tooling',                  model: 'sonnet', phase: 'Phase E: Coach fork Route B' },
  { n: 15, title: 'Document routes in README',                 model: 'sonnet', phase: 'Phase E: Coach fork Route B' },
  { n: 16, title: 'Security hardening (signal sanitization)',  model: 'opus',   phase: 'Phase F: Hardening, uninstall, Windows, docs' },
  { n: 17, title: 'Single-command complete uninstall',         model: 'sonnet', phase: 'Phase F: Hardening, uninstall, Windows, docs' },
  { n: 18, title: 'Windows support (ps1 wrappers + hooks)',    model: 'sonnet', phase: 'Phase F: Hardening, uninstall, Windows, docs' },
  { n: 19, title: 'Documentation overhaul',                    model: 'sonnet', phase: 'Phase F: Hardening, uninstall, Windows, docs' },
]

const RESULT_SCHEMA = {
  type: 'object',
  required: ['task', 'status', 'summary'],
  properties: {
    task: { type: 'number' },
    status: { type: 'string', enum: ['completed', 'already_done', 'blocked', 'failed'] },
    commit: { type: 'string', description: 'Short SHA of the commit this task produced (or reused), empty if none' },
    summary: { type: 'string', description: 'One-paragraph account of what was done and what was verified' },
    blocker: { type: 'string', description: 'Only for blocked/failed: exact observed evidence (command output), never speculation' },
  },
}

function taskPrompt(t) {
  return [
    'You are executing ONE task of a written implementation plan, exactly as specified, inside the current git worktree (branch worktree-copilot-coach-plan).',
    '',
    `PLAN FILE: ${PLAN}`,
    `YOUR TASK: "### Task ${t.n}: ..." (${t.title}). Read the plan file's Global Constraints section AND your task section in full before acting. Execute ONLY task ${t.n}.`,
    '',
    'PROGRESS JOURNAL (append-immediately, rate-limit-proof):',
    `- The journal is ${PROGRESS} (JSONL, one object per line). It may not exist yet; create it on first append.`,
    `- IMMEDIATELY on starting, append: {"ts":"<date -Iseconds>","task":${t.n},"event":"start","attempt":<1 + number of prior start events for this task>}`,
    `- After EACH plan step completes (test written, test failed as expected, implementation done, test passed, committed), append one line: {"ts":"...","task":${t.n},"event":"step","step":"<step label>","ok":true|false,"detail":"<one line>"}`,
    '- Append with >> redirection the moment each step finishes. Never batch journal writes for the end.',
    `- On finishing, append: {"ts":"...","task":${t.n},"event":"end","status":"<your final status>","commit":"<short sha or empty>"}`,
    '- NEVER git-add or commit the journal file. The plan\'s commit commands list explicit paths; keep it that way.',
    '',
    'IDEMPOTENT RESUME (do this BEFORE any work):',
    `1. Read ${PROGRESS} if it exists. Read \`git log --oneline -20\`.`,
    `2. If a commit matching task ${t.n}'s planned commit message already exists AND the task's test command passes when you run it now, do NOT redo anything: append an end event with status already_done and return {"task":${t.n},"status":"already_done",...}.`,
    `3. If the journal shows task ${t.n} was started but not committed, resume from the first step whose artifacts are missing or whose test fails — verify by running the plan's test commands, not by trusting the journal. Do not repeat steps whose artifacts exist and whose tests pass.`,
    '',
    'EXECUTION RULES:',
    '- Follow the task steps in order: failing test first, watch it fail, implement, watch it pass, commit with the exact message given.',
    '- Use the exact file paths, code, and commands from the plan. Where the plan instructs deriving something from real code (e.g. <ANALYZER_EXPR>), derive it exactly as instructed — never invent an alternative.',
    '- Run every "Run:" command and compare against the stated "Expected:" output.',
    '- If anything deviates from Expected, stop, investigate, and only proceed once resolved within the plan\'s letter. If it cannot be resolved without deviating from the plan, return status failed with the exact evidence in blocker.',
    t.gate
      ? '- THIS IS A HARD-STOP GATE TASK: if live verification does not match Expected, record the observed behavior in docs/verification-log.md exactly as the plan instructs, append a journal end event, and return status blocked with the evidence. NEVER improvise workarounds, alternative schemas, or skipped checks.'
      : '- Before returning, re-run the task\'s test command one final time and require it green.',
    '',
    'Your final message must be only the structured result (the StructuredOutput tool).',
  ].join('\n')
}

// ---------------------------------------------------------------------------
// Sequential executor. Tasks are strictly ordered (each builds on the prior
// commit), so there is no parallelism here by design.
// Resume layers:
//   1. Workflow-level: relaunch with {scriptPath, resumeFromRunId} — completed
//      agent() calls return cached results instantly (same prompt+opts).
//   2. args.startTask: skip tasks already confirmed done in an earlier run.
//   3. Task-level: every agent self-checks git log + the journal and skips
//      finished steps, so even a re-run of an interrupted task repeats nothing.
// ---------------------------------------------------------------------------
const startTask = (args && args.startTask) || 1
const results = []

for (const t of TASKS) {
  if (t.n < startTask) {
    log(`Task ${t.n} skipped (startTask=${startTask})`)
    continue
  }

  const res = await agent(taskPrompt(t), {
    label: `task-${t.n}: ${t.title}`,
    phase: t.phase,
    model: t.model,
    schema: RESULT_SCHEMA,
  })

  if (!res) {
    // Agent died (rate limit / terminal API error) or was skipped by the user.
    log(`Task ${t.n} agent died or was skipped. HALTING. Resume with {scriptPath, resumeFromRunId} — completed tasks are cached; task ${t.n} will self-resume from its journal.`)
    return {
      halted_at_task: t.n,
      reason: 'agent_died_or_skipped',
      resume_hint: `Workflow({scriptPath, resumeFromRunId: '<this runId>'}) or args {startTask: ${t.n}}`,
      results,
    }
  }

  results.push(res)
  log(`Task ${t.n} [${t.model}]: ${res.status}${res.commit ? ' @ ' + res.commit : ''} — ${res.summary.slice(0, 140)}`)

  if (res.status === 'blocked' || res.status === 'failed') {
    log(`Task ${t.n} ${res.status.toUpperCase()}: ${(res.blocker || '').slice(0, 300)}`)
    log('HALTING per plan (hard-stop semantics). Fix the blocker, then resume with resumeFromRunId (cached prefix) or args {startTask: ' + t.n + '}.')
    return { halted_at_task: t.n, reason: res.status, blocker: res.blocker || '', results }
  }
}

// ---------------------------------------------------------------------------
// Final integration check (plan's closing checklist)
// ---------------------------------------------------------------------------
phase('Final checks')
const finalCheck = await agent(
  [
    'Run the "Final integration check" checklist at the end of ' + PLAN + ' in the current worktree:',
    '1. Run every test: `for t in tests/test-*.sh; do echo "== $t"; bash "$t" || exit 1; done; python3 tests/test-coach-rules-eval.py && python3 tests/test-coach-signals.py`',
    '2. Run `bash install.sh --dry-run` and confirm no missing-script warnings.',
    '3. Confirm docs/verification-log.md contains Gate 1 (including "temporary hooks removed: YES"), Gate 2, and Gate 3 sections with PASS verdicts.',
    '4. Run the four-state coach flag matrix smoke test using the env pattern from tests/test-coach-signals.py (off/off deletes signals file; on/off; off/on; on/on export wins).',
    '5. Confirm `grep -c self-learning ~/.claude/settings.json` is 0 (or equal to its pre-plan value) — the gates must not have left standing hooks installed.',
    '6. Confirm the sandboxed uninstall round-trip passed (tests/test-uninstall.sh is part of the step-1 loop; call out its result explicitly).',
    `Append each check's outcome to ${PROGRESS} immediately as {"ts":"...","task":"final","event":"step",...}. Do not commit the journal.`,
    'Report exactly what passed and what failed with command output evidence. Fix nothing.',
  ].join('\n'),
  {
    label: 'final-integration-check',
    phase: 'Final checks',
    model: 'opus',
    schema: {
      type: 'object',
      required: ['all_passed', 'details'],
      properties: {
        all_passed: { type: 'boolean' },
        details: { type: 'string' },
      },
    },
  },
)

return {
  completed_tasks: results.length,
  task_results: results,
  final_check: finalCheck || { all_passed: false, details: 'final-check agent died; re-run with resumeFromRunId' },
}
