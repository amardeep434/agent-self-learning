# Neutrality Remediation Implementation Plan (2026-07-31)

> **For agentic workers:** Execute tasks IN ORDER. Do NOT deviate or add scope. The findings doc `/home/amardeep/.claude/jobs/79e9b34f/tmp/audit/neutrality-analysis.md` is the evidence base — every task cites its finding IDs; read the cited finding before executing its task. If a cited line has drifted, adapt minimally to the finding's INTENT and journal the delta. Respect the findings doc's **EXEMPT ledger** absolutely: nothing listed there gets rewritten.

**Goal:** Remove harness bias (Claude-Code-centric language, naming, and structural asymmetries) and platform bias (silent Linux assumptions) identified by the 2026-07-31 neutrality analysis, on a tree that claims Claude Code / Copilot CLI / VS Code Copilot Chat as peers with Windows/macOS support.

**Architecture:** Six work packages as independent commits on one branch off `main`: symmetric absence test first (it pins the property the rest of the work claims), then prompt/constant de-Clauding, curator env migration, health parity, the indexing decision gate, and a doc-polish batch.

**Tech Stack:** bash (POSIX-compatible), Python 3.9+ stdlib only, `tests/run-all.sh` glob discovery.

## Global Constraints (binding — same as the repo's CLAUDE.md)

- git log is truth; probe, never infer; an empty grep proves nothing — positive probes only.
- Fail loudly: degraded outcomes get named reasons in persist-failures.log.
- Sandbox any ad-hoc store-touching run: `env -i HOME=<tmp> PATH="$PATH" AGENT_LEARNING_HOME=<tmp>/store SL_CONFIG_FILE=/nonexistent bash scripts/<script>.sh`
- Never hardcode a suite count. Conventional commits, no attribution lines.
- Deprecation pattern for renamed env vars/literals: new name primary, old honored one release with stderr notice — copy `scripts/skill-lifecycle.py:88-105` (`_days_env`).
- Base branch: `main` (PR #17 merged as ed84066). Branch name: `fix/neutrality-2026-07-31`.

## Journal (resume protocol)

`/home/amardeep/.claude/jobs/79e9b34f/tmp/audit/execution-journal-2.md`. First action: if it exists, read it and resume at the first unticked task; else create it with the task list (0, WP1-WP6, G1-G5) unticked. Append `- [x] <task> — <sha> — <note/delta>` after EVERY commit, never batched.

---

### Task 0: Branch + plan/findings committed

- [ ] `git checkout main && git pull && git checkout -b fix/neutrality-2026-07-31`
- [ ] Copy this plan to `docs/superpowers/plans/2026-07-31-neutrality-remediation.md` and the findings doc to `docs/superpowers/2026-07-31-neutrality-analysis.md` (findings are the audit record; plans dir is for the plan).
- [ ] Commit: `docs: add neutrality analysis and remediation plan`

### Task WP1: symmetric absence guard [T1, C1 — HIGH]

**Files:** Create `tests/test-copilot-absent.sh`; Modify `CLAUDE.md` (the :17-19 guard sentence).

- [ ] **Step 1:** Read `tests/test-claude-absent.sh` in full — mirror its structure exactly (isolated HOME, PATH surgery, fake binary, the detached-pipeline waiter `tests/lib/wait-for-review.sh`).
- [ ] **Step 2:** New test: fake `claude` on PATH, NO `copilot` binary, NO `~/.copilot` directory. Run the Claude-path pipeline end to end: `session-review.sh` (via its hook entry with a fixture transcript), `session-start-context.sh`, `mirror-skills` publication, `index-session.sh`. Assert: persistence happened (byte-count delta on the sandbox store's MEMORY.md, per the repo's own measure-bytes rule), no failure line names copilot as a hard requirement, and nothing attempted to create `~/.copilot`. Header comment cites `tests/test-vscode-session-review.sh:110-129` as the existing VS Code no-copilot fallback coverage rather than duplicating it.
- [ ] **Step 3:** Run the new suite standalone; then confirm `tests/run-all.sh` discovers it (glob) — verify by name in its output.
- [ ] **Step 4:** CLAUDE.md guard sentence now names BOTH guards: test-claude-absent.sh (Copilot path needs no Claude) and test-copilot-absent.sh (Claude/VS Code paths need no Copilot).
- [ ] **Step 5:** Commit: `test: add test-copilot-absent.sh — the absence guard now runs both directions`

### Task WP2: de-Claude shared prompts + author constant [P1, P2, P3, N6 — HIGH]

**Files:** `prompts/curator-review.md:1`, `prompts/authoring-standards.md:68,82,145,112`, `config/claude-md-snippet.md:104`.

- [ ] **Step 1:** curator-review.md:1 → "You are the Curator for this agent self-learning skill library (shared by Claude Code, GitHub Copilot CLI and VS Code Copilot Chat)."
- [ ] **Step 2:** `grep -rn "claude-code-review" .` (whole repo). Introduce neutral literal `agent-review` at every author-field mention; add one sentence in authoring-standards.md: the legacy `claude-code-review` literal remains valid on read for one release. If the grep reveals any code-side validator or emitter of the literal (analysis found none — re-verify), apply the read-shim pattern there.
- [ ] **Step 3:** authoring-standards.md:112 tool-naming rule → "Reference tools by the harness's own tool name where one exists; prefer harness-neutral phrasing ('read the file') over shell commands."
- [ ] **Step 4:** Run any suites pinning prompt text (`grep -l authoring-standards tests/` and `grep -rln "claude-code-review" tests/`) → adjust pins to the new literal. Commit: `fix: neutral curator identity, agent-review author literal, harness-neutral tool naming`

### Task WP3: curator env-var migration [N1, L1 — MEDIUM]

**Files:** `scripts/curator-run.sh:4,16-17,41-42`, `tests/test-store-lock-writers.py:282`, `README.md` config table.

- [ ] **Step 1 (RED):** Extend whichever suite covers curator config (or test-store-lock-writers.py:282's usage) with: `SL_CURATOR_IDLE_GATE`/`SL_CURATOR_LLM_PASS` are honored as primary; legacy `CLAUDE_CURATOR_*` still work and print a deprecation notice on stderr. Run → FAIL.
- [ ] **Step 2 (GREEN):** curator-run.sh: `IDLE_GATE_HOURS="${SL_CURATOR_IDLE_GATE:-${CLAUDE_CURATOR_IDLE_GATE:-2}}"` plus a stderr deprecation echo when the legacy var is set and the new one is not (bash equivalent of skill-lifecycle.py's `_days_env`). Same for LLM_PASS. Update the :16-17 usage comment and the :4 scheduler comment → "Triggered by any scheduler (cron / systemd timer / Windows Task Scheduler / launchd) or a harness routine."
- [ ] **Step 3:** README config table: add the two SL_CURATOR_* rows (documenting defaults 2 / false and the one-release legacy names). Run curator + store-lock suites → PASS. Commit: `fix: SL_CURATOR_* primary config names with one-release CLAUDE_ shims`

### Task WP4: health parity for VS Code [T3 — MEDIUM]

**Files:** `scripts/self-learning-health.sh` (after the :254 Copilot section), matching test.

- [ ] **Step 1:** Read `scripts/doctor.sh:326-347` (the VS Code report block) and the two existing health hook-registration sections.
- [ ] **Step 2 (RED):** If a `tests/test-health-*` suite pins section names, add the "Hook Registration (VS Code Copilot Chat)" expectation → FAIL. If none pins sections, add the check to `tests/test-health-copilot-hooks.sh`'s pattern in a new or existing suite.
- [ ] **Step 3 (GREEN):** Add the section: WARN-level (never FAIL — VS Code may legitimately ride the shared ~/.claude settings), checking the store-rendered `<store>/vscode-hooks.json` existence and echoing the `chat.hookFilesLocations` registration reminder, modeled on doctor.sh's block. Run health suites → PASS.
- [ ] **Step 4:** Commit: `fix: health reports VS Code hook registration alongside Claude and Copilot`

### Task WP5: Copilot indexing — probe-gated decision [A1, S1, A3, R1 — MEDIUM]

**Files:** possibly `scripts/index-session.sh` / new `index-copilot-session` path, `schema/session-search-schema.sql:19`, `README.md:340`.

- [ ] **Step 1 (PROBE, decides the branch):** Determine whether Copilot indexing is mechanical with what exists: does `scripts/lib/transcript.py` already parse Copilot `session-state/*/events.jsonl` into the message shape `index-session.py` ingests, and do `tests/fixtures/` contain a Copilot session fixture? (`grep -n "copilot" scripts/lib/transcript.py | head`; `ls tests/fixtures/`). Journal the probe result verbatim.
- [ ] **Step 2a (probe says YES):** Implement: extend the indexing path to walk `~/.copilot/session-state/*/` through transcript.py into the same schema (source label per harness), with a fixture-driven test mirroring `tests/test-index-session-first-run.sh`. Update README:340 to ✅ and the schema :19 comment → "one row per harness session (Claude Code JSONL and Copilot CLI session-state)". 
- [ ] **Step 2b (probe says NO — parser or fixture missing):** Do NOT build an inferred parser (rule 3). Instead: README:340 "❌ planned" → "❌ not implemented — needs a probed Copilot event-to-message mapping; see docs/superpowers/plans/2026-07-31-neutrality-remediation.md WP5"; schema :19 comment → "one row per harness session (currently populated from Claude Code JSONL only — see index-session.sh)". Journal which branch ran and why.
- [ ] **Step 3:** Run index suites → PASS. Commit: `feat: index Copilot sessions into the shared search schema` or `docs: truthful status for Copilot session indexing`.

### Task WP6: doc polish batch [R2, R3, R4, R5, R8/N5, C2, A2, T4 — LOW]

- [ ] **Step 1:** README: per-harness skill-publication check at :359-363 (state that `~/.claude/skills` is checked for Claude AND VS Code — verify against mirror-skills.py:82-100 — and `~/.copilot/skills` for Copilot); Windows doctor line at :30 ("run inside Git Bash on Windows"); requirements wording at :46 ("at least one of the two CLIs — the VS Code adapter reviews through one of them"); hooks-section lead-in sentence at :134 ("registration is per harness; Copilot CLI is automatic, the other two are manual").
- [ ] **Step 2:** `grep -rn "claude-md-snippet" .` then rename `config/claude-md-snippet.md` → `config/agent-context-snippet.md` (git mv), update every reference found (README:596 and any code hits), description → "self-learning protocol for the agent context file (CLAUDE.md / AGENTS.md)".
- [ ] **Step 3:** CLAUDE.md sandbox recipe: add one line "(on Windows, run inside Git Bash)". docs/coach-integration.md data-sources: one sentence naming VS Code as not-a-telemetry-source with the verified reason (check what telemetry.py reads before writing the reason). install.sh:673 → "(Claude Code / VS Code shared file)".
- [ ] **Step 4:** Also from the exempt ledger's one action item [N2]: pin the deprecation-removal milestone — add one line to the README deprecation notes: "legacy CLAUDE_-prefixed names are removed in the release after 2026-08." Run `tests/run-all.sh`-adjacent doc-pinning suites (`grep -rln "claude-md-snippet\|snippet" tests/`) → PASS. Commit: `docs: neutrality polish — per-harness checks, Windows lines, snippet rename, deprecation milestone`

### FINAL GATE

- [ ] **G1:** live-store byte count before (`du -sb ~/.local/share/agent-learning | cut -f1`) → journal.
- [ ] **G2:** `bash tests/run-all.sh` → all suites pass (count from its own output, don't pin).
- [ ] **G3:** byte count after → compare, journal any delta with attribution.
- [ ] **G4:** `git log --oneline main..HEAD` — conventional format, one commit per WP.
- [ ] **G5:** Push `-u origin fix/neutrality-2026-07-31`, open DRAFT PR to main titled `Neutrality remediation: symmetric guards, de-Clauded prompts and knobs, platform-neutral docs`, body: per-WP summary + WP5 probe verdict + test plan. Journal branch, PR URL, deltas.
