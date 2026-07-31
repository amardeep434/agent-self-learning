# Neutrality analysis — branch fix/audit-remediation-2026-07-31

Tree: /home/amardeep/claude-self-learning/.claude/worktrees/agent-a1fbfc3731d049c55 @ f54cf87

## PROGRESS

- [x] D1a README.md language sweep
- [x] D1b CLAUDE.md language sweep
- [x] D1c docs/*.md (top-level: platform-coverage, coach-integration, others)
- [x] D1d docs/superpowers/** (plans, handoffs, spike)
- [x] D1e prompts/*.md
- [x] D1f .github/ workflows + templates
- [x] D1g schema/ comments
- [x] D2a CLAUDE_ env vars / identifiers grep (scripts/ config/ tests/)
- [x] D2b file names, log strings, persist-failure reason strings
- [x] D3a shared libs reading ~/.claude or assuming claude binary (lib/, paths.py, review-common)
- [x] D3b test-claude-absent.sh coverage honesty + copilot/vscode-absent asymmetry
- [x] D3c install.sh / install.ps1 / doctor.sh / health output text
- [x] D4 Linux-assumed documentation (commands, /tmp, apt vs winget)
- [x] D5 Linux-assumed code claimed cross-platform (GNU flags, /tmp, nohup, paths.py Windows behavior vs docs)
- [x] D6 structural asymmetries feature table (review, indexing, doctor, curator, skills mirroring per harness)

## Findings

### D1a README.md

Overall: README is already substantially neutralized (title, intro, peer framing, store resolution). Remaining items:

- **R1 (MEDIUM)** README.md:340 — Session search row: Claude ✅ "(Claude JSONL)", Copilot "❌ planned", VS Code "❌ not wired — `index-session.sh` reads `~/.claude/projects`". Honest disclosure of gap, BUT the feature itself is a shared-pipeline capability delivered Claude-only. This is a structural asymmetry (cross-ref D6), the doc is honest → the doc side is EXEMPT; the code gap is the finding.
- **R2 (MEDIUM)** README.md:359-363 — verification snippet for "skill publication (Route A)" only shows the Claude location: `ls ~/.claude/skills/*/.self-learning-managed`. No equivalent command for where Copilot/VS Code users check publication. Fix: add the per-harness check commands (or state explicitly that publication targets `~/.claude/skills` for ALL harnesses because VS Code reads it and Copilot has no skills dir — whichever is true per scripts/; verify in D6).
- **R3 (LOW)** README.md:30 — Quick start `bash scripts/doctor.sh` has no PowerShell/Windows line, while install does (`.\install.ps1`). Windows user left without the doctor step. Fix: add `bash scripts/doctor.sh` note "(run inside Git Bash on Windows)" or a doctor line under the PowerShell block.
- **R4 (LOW)** README.md:46 — "(at least one of Claude Code / Copilot CLI must be installed)" — accurate (VS Code adapter delegates to one of those CLIs) but reads as a two-harness project; fix wording: "at least one of the two CLIs (Claude Code or Copilot CLI) — the VS Code adapter reviews through one of them".
- **R5 (LOW)** README.md:134-206 — "Registering hooks" lists Claude Code first and its section is the longest/most detailed; Copilot gets 2 lines. Content-wise justified (Claude needs manual merge; Copilot is automatic), so ordering is cosmetic. Optional fix: lead with the sentence "hooks are registered per harness; Copilot CLI is automatic, the other two are manual" so brevity reads as ease, not neglect.
- **R6 (EXEMPT)** README.md:105-129, 127-129 — diagram/notes name "Claude Code subagent or Copilot CLI, per harness" — already symmetric; VS Code absent from the reviewer parenthetical is accurate (it delegates).
- **R7 (EXEMPT)** README.md:213-217, 449-453, 483-489 — every `~/.claude` mention is either the harness-owned-config exception (deliberate, stated) or the shared-hook-file trap (VS Code core behavior, honestly documented).
- **R8 (LOW)** README.md:596 — `claude-md-snippet.md   self-learning protocol for CLAUDE.md` — file name and description are Claude-only for what CLAUDE.md itself says is also delivered via AGENTS.md (Copilot reads AGENTS.md). Verify actual injector target in D2b/D6; if the snippet serves both AGENTS.md and CLAUDE.md, rename/redescribe (e.g. `agents-md-snippet.md`, "self-learning protocol for the agent context file (AGENTS.md / CLAUDE.md)").

### D1b CLAUDE.md

- **C1 (MEDIUM)** CLAUDE.md:17-19 — "`tests/test-claude-absent.sh` is the regression guard: the Copilot review path must work with no `claude` binary and no `~/.claude`". Guard is one-directional. There is no stated `test-copilot-absent` guard that the Claude/VS Code paths work with no `copilot` binary / no `~/.copilot` — yet `SL_VSCODE_REVIEWER` auto-detect PREFERS copilot, so the VS Code path has a real copilot-absent branch ("If neither CLI is on PATH…"). Verify in D3b whether such a test exists; if not: HIGH structural finding, add symmetric test.
- **C2 (LOW)** CLAUDE.md sandbox example (hard rule 1) is bash/env-i only; no Windows equivalent though Windows dev is claimed CI-green. Dev-facing, acceptable → LOW. Fix: one line "on Windows run inside Git Bash".
- **C3 (EXEMPT)** "The local folder is still named `claude-self-learning` — do not rename" — explicitly constrained; record as constraint.
- **C4 (EXEMPT)** `07-implementation-guide-for-claude-code.md` reference — historical research corpus.
### D1c docs/*.md (top level)

- **D1 (EXEMPT)** docs/verification-log.md — header at :6 explicitly flags that entries predate the vendor-neutral store and still say `~/.claude/...`. Historical record, correctly labeled.
- **D2 (EXEMPT)** docs/project-creation-plan.md — the original creation plan, `~/.claude`-everything. Historical. Optionally add a one-line banner like verification-log.md's if it lacks one (verify — it starts with "Plan:" and cites a 2026 source path; low value).
- **D3 (EXEMPT)** docs/upstream-audit-2026-07-30.md, docs/windows-verification-runbook.md — the runbook is written FOR a machine without Claude Code (neutrality-positive); the audit is a dated record.
- **D4 (EXEMPT)** docs/coach-integration.md:60,113-114,138-141 — names both Copilot and Claude parsers/stores symmetrically; Claude mentions are factual descriptions of upstream Coach behavior.
- **D5 (EXEMPT)** docs/platform-coverage.md:41 — "Copilot or Claude store" symmetric; the doc is the honest platform ledger.

### D1e prompts/*.md

- **P1 (HIGH)** prompts/curator-review.md:1 — "You are the Curator for Claude Code's self-learning skill library." This prompt curates the SHARED store and can be run by a human whose only harness is Copilot. Fix: "You are the Curator for this agent self-learning skill library" (or "…for the agent-learning store shared by Claude Code, Copilot CLI and VS Code Copilot Chat").
- **P2 (HIGH)** prompts/authoring-standards.md:68,82,145 — the `author` field is pinned to the literal `claude-code-review` for ALL agent-created skills, including ones proposed by a Copilot reviewer. Value is a schema constant (good: never environment-derived) but the constant itself encodes one harness. Fix: introduce neutral literal (e.g. `agent-review` or `self-learning-review`), accept the old literal on read for one release (same deprecation pattern as CLAUDE_REVIEW_ENABLED), update authoring-standards.md, config/claude-md-snippet.md:104, and wherever persist/validation checks the field (grep found no code enforcement — verify again during fix; the literal appears only in prompts/config docs, so migration is doc+prompt-side plus whatever reviewers emit).
- **P3 (MEDIUM)** prompts/authoring-standards.md:112 — "Reference tools by Claude Code name. Say 'Read' not cat/head/tail." Skills are injected into Copilot/VS Code sessions too, where tool names differ. Fix: "Reference tools by the harness's tool name where one exists; prefer harness-neutral phrasing ('read the file') over shell commands."

### D1f .github/

- **G1 (OK/none)** .github contains only workflows/ci.yml; `grep -i claude .github/workflows/` — no matches. No issue/PR templates exist. No findings.

### D1g schema/

- **S1 (LOW)** schema/session-search-schema.sql:19 — comment "sessions - one row per Claude Code session". Schema is the harness-neutral store's; only the *indexer* is Claude-only today. Fix comment: "one row per harness session (currently populated from Claude Code JSONL only — see index-session.sh)". Cross-ref D6 indexing asymmetry.

### D1d docs/superpowers/**

- **SP1 (EXEMPT)** All of docs/superpowers/ — dated plans (2026-07-22/25/30/31), handoffs, and the vscode spike are point-in-time records; the 2026-07-25 plan already carries 9 SUPERSEDED callouts. Historical record per rules of evidence; do not rewrite.
- **SP2 (LOW, verify during fix)** docs/superpowers/plans/2026-07-30-learned-context-delivery.md and 2026-07-31-* are RECENT plans that may still be live guidance; if any instructs a Claude-only delivery path presented as the general one, add a callout rather than rewrite. Not blocking.
### D2a CLAUDE_ identifiers (scripts/ config/ tests/)

- **N1 (MEDIUM)** scripts/curator-run.sh:16-17,41-42 — `CLAUDE_CURATOR_IDLE_GATE` and `CLAUDE_CURATOR_LLM_PASS` are LIVE, PRIMARY config vars (not deprecation shims): `IDLE_GATE_HOURS="${CLAUDE_CURATOR_IDLE_GATE:-2}"`, `LLM_PASS="${CLAUDE_CURATOR_LLM_PASS:-false}"`. No `SL_` equivalent exists (`grep -rn SL_CURATOR scripts/ config/ tests/` → empty; positive probe: the only curator knobs are these two). Curator runs on the shared store for all harnesses. Also absent from the README config table → undocumented AND Claude-branded. Fix: add `SL_CURATOR_IDLE_GATE`/`SL_CURATOR_LLM_PASS` as primary, honor CLAUDE_ names one release with stderr deprecation (exact pattern already in scripts/skill-lifecycle.py:88-105 and lib/config.sh), update tests/test-store-lock-writers.py:282 and README config table.
- **N2 (EXEMPT)** `CLAUDE_REVIEW_ENABLED` (lib/config.sh, tests/test-config.sh:64-69), `CLAUDE_LEARNED_SKILLS_DIR`, `CLAUDE_SKILL_STALE_DAYS`, `CLAUDE_SKILL_ARCHIVE_DAYS` (scripts/skill-lifecycle.py:47-105) — deliberate one-release deprecation shims with stderr warnings, documented in README:508-509,549-551. Correct migration pattern; only note: define the removal release somewhere so "one release" doesn't rot.
- **N3 (EXEMPT)** scripts/lib/telemetry.py `CLAUDE_*` constants (:253-396,845 `CLAUDE_CONFIG_DIR`), scripts/coach-rules-eval.py `CLAUDE_PLAN_MODE_TOOL` uses — adapter-side parsers of Claude Code's OWN on-disk format and env var, mirroring upstream Coach's parser-claude.ts names. Adapter code may be harness-specific; symmetric Copilot parsing exists in the same file.
- **N4 (EXEMPT)** scripts/doctor.sh:277 `CLAUDE_SETTINGS` — local var in the Claude-adapter reporting block; a sibling Copilot block exists.

### D2b File names / log strings

- **N5 (LOW)** config/claude-md-snippet.md — filename says "claude-md" but content (:1-16) is fully harness-neutral ("shared by Claude Code, Copilot CLI and VS Code Copilot Chat as peers"). The artifact is injected as learned context for ALL harnesses (Copilot reads AGENTS.md). Fix: rename to `config/agent-context-snippet.md` (or `learning-protocol-snippet.md`), keep description "self-learning protocol for the agent context file (CLAUDE.md / AGENTS.md)"; update README:596 and any referencing code (grep `claude-md-snippet` at fix time).
- **N6 (LOW)** config/claude-md-snippet.md:104 — "Author field: always \"claude-code-review\"" — same constant as P2; fix together.
- **N7 (EXEMPT)** docs/research/07-implementation-guide-for-claude-code.md and the research corpus — historical, per task rules.
- **N8 (EXEMPT/CONSTRAINT)** local folder `claude-self-learning` — CLAUDE.md forbids renaming (worktree link). Constraint, not finding.
- Log/reason strings: `sl_review_no_reviewer_available <name> <dir> claude|copilot` passes the missing binary's name as data — symmetric, no bias found in reason strings (checked scripts/*.sh grep for claude in echo/log lines; hits were doctor.sh adapter-report lines and legacy-store warnings, both correct).
### D3a Shared code paths

- **CP1 (verified clean)** Shared libs (scripts/lib/paths.py, config.sh, review-common.sh, store_lock.py, jsonio.py, proposal_schema.py, transcript.py, session_db.py) — no `~/.claude` reads, no `claude` binary assumption found; paths.py resolution is AGENT_LEARNING_HOME → XDG → LOCALAPPDATA → ~/.local/share, never ~/.claude. Positive probe: the ONLY ~/.claude reads in shipped scripts are index-session.sh:20 (Claude adapter, its job), mirror-skills.py:98 (one of two symmetric mirror targets, copilot sibling at :99), doctor.sh/self-learning-health.sh adapter-report blocks, and inject-agents-md.py doc comments describing what it does NOT do.
- **CP2 (verified clean)** scripts/mirror-skills.py:87-100 — symmetric `("claude", ~/.claude/skills), ("copilot", ~/.copilot/skills)` targets; VS Code deliberately covered via the claude target with the inference honestly labeled "NOT a measured fact" (:82-86).
- **CP3 (verified clean)** doctor.sh:275-305 — the three harness blocks are symmetric; "absent" wording is peer-neutral in both directions ("normal on a Copilot-only or VS-Code-only machine" / "normal on a Claude-Code-only or VS-Code-only machine").

### D3b test-claude-absent honesty + asymmetry

- **T1 (HIGH)** No `tests/test-copilot-absent.sh` exists (positive probe: full tests/ listing read; the only no-copilot coverage is one assertion inside tests/test-copilot-session-review.sh:288 — the COPILOT adapter refusing to spawn without its own binary — and fake-CLI reviewer-selection checks in test-vscode-session-review.sh:110-129). `tests/test-claude-absent.sh` proves the Copilot path needs no Claude; nothing proves the Claude Code and VS Code paths (session-review.sh, session-start-context.sh + mirror + injection, index-session.sh, coach/telemetry reads of `~/.copilot/session-store.db`) survive a machine with no `copilot` binary and no `~/.copilot` directory. "Peers" implies the guard runs both ways. Fix: add `tests/test-copilot-absent.sh` mirroring test-claude-absent.sh's structure (fake `claude` on PATH, no `copilot`, no ~/.copilot; run session-review.sh end to end via the detached-pipeline waiter; assert persistence happened and no reference to copilot leaked). Also add the VS Code no-copilot case if not already covered by test-vscode-session-review's claude-fallback check (it is, with fakes — cite it in the new test's header instead of duplicating).
- **T2 (EXEMPT)** test-claude-absent.sh's own coverage is honest: it fakes `copilot`, strips `claude` from PATH, uses an isolated HOME — matches its stated claim.

### D3c install/doctor/health output text

- **T3 (MEDIUM)** scripts/self-learning-health.sh — has "Hook Registration (Claude Code)" (:192) and "Hook Registration (Copilot CLI)" (:254) sections but NO VS Code section, while doctor.sh does report VS Code (:326-347). health is "the command users are actually told to run" (its own comment :250). Partially covered because VS Code runs the ~/.claude/settings.json hooks, but the store-rendered `<store>/vscode-hooks.json` + `chat.hookFilesLocations` registration path is unchecked. Fix: add a "Hook Registration (VS Code Copilot Chat)" WARN-level section modeled on doctor.sh:326-347.
- **T4 (LOW)** install.sh:673 — "NEXT STEP (Claude Code only): Register hooks in ~/.claude/settings.json" — accurate and labeled; VS Code instructions printed in step 4c. No fix needed beyond possibly "(Claude Code / VS Code shared file)". Otherwise install.sh output is peer-ordered (Copilot 4b, VS Code 4c, Claude last) and refusal/skip messages are symmetric.
### D4 Linux-assumed documentation

- **L1 (LOW)** scripts/curator-run.sh:4 — "Triggered by cron, systemd timer, or Claude Code routine." Doubly biased: scheduling examples are Linux-only (no Windows Task Scheduler / macOS launchd) AND the only harness named is Claude Code. Fix: "Triggered by any scheduler (cron / systemd timer / Windows Task Scheduler / launchd) or a harness routine." Also there is no README section on scheduling the curator at all — verify at fix time; if absent, the one-liner in the script header is the only guidance and should be neutral.
- **L2 (LOW)** CLAUDE.md sandbox recipe (= C2) and README:30 doctor line (= R3) — bash-only where Windows support is claimed. Both already recorded.
- **L3 (EXEMPT)** "Linux-only measured" claims (VS Code adapter, README:56,341-344,392-396; CLAUDE.md VS Code section) — honest disclosures per docs/platform-coverage.md; keep verbatim.
- **L4 (EXEMPT)** docs/windows-verification-runbook.md + install.ps1/uninstall.ps1 + README Windows-notes column — Windows path is documented first-class; no silent Linux assumption found in install docs.

### D5 Linux-assumed code claimed cross-platform

- **Verified clean, with probes:**
  - `stat`: only shell use is self-learning-health.sh:301 with `stat -c || stat -f || echo 0` fallback chain. list-transcripts.py replaced the old shell pipeline.
  - `date -d`: lib/config.sh:190-249 documents and ships the portable replacement; remaining `date -u +%Y…` calls (curator-run.sh:273,280) are POSIX-portable format-only.
  - `/tmp`: no hardcoded /tmp in shipped scripts (hits are comments/attack-string examples); temp files via mktemp / tempfile APIs.
  - `nohup … &`: runs under Git Bash on Windows (the project's stated Windows substrate); detached-review semantics on Windows are covered by CI suites with skips ledgered in docs/platform-coverage.md.
  - paths.py: real `%LOCALAPPDATA%` branch (resolve_home, :65-66) + MSYS/native argv and CRLF handling (:129-191); README:220-224 describes exactly what the code does. Docs and code agree.
- **L5 (EXEMPT)** Windows TOCTOU writer fallback and WSL-vs-Git-Bash ambiguity — known residuals, loudly documented (README:403-414), doctor prints the writer in force.

### D6 Structural asymmetry table (docs claim vs code reality)

| Capability | Claude Code | Copilot CLI | VS Code | Docs state gap? | Verdict |
|---|---|---|---|---|---|
| Session-end review | session-review.sh | copilot-session-review.sh | vscode-session-review.sh (delegates CLI) | yes | symmetric |
| Turn counting | PostToolUse | not wired (deliberate) | PostToolUse (required) | yes (README:338) | documented design choice |
| Session-start injection + skill mirror | settings-hooks.json (manual merge) | copilot-hooks.json (auto) | via ~/.claude settings share | yes | symmetric |
| Skill publication targets | ~/.claude/skills | ~/.copilot/skills | via claude target (inference, labeled) | yes (mirror-skills.py:82-86) | symmetric |
| **Session search indexing** | index-session.sh (~/.claude/projects) | **absent — "❌ planned"** | absent, stated | yes (README:340) | **A1 below** |
| Doctor | full 3-harness report | full | full | n/a | symmetric |
| **self-learning-health.sh** | section | section | **no section** | **no** | **= T3** |
| Curator | harness-agnostic store pass | same | same | yes | symmetric; but knobs are CLAUDE_-branded (= N1) and prompt is Claude-branded (= P1) |
| Coach telemetry | Claude transcripts | Copilot events.jsonl + session-store.db + workspace.yaml | not a telemetry source | partially | **A2 below** |

- **A1 (MEDIUM)** Copilot session indexing is absent while Claude's exists (`scripts/index-session.sh:20` hardcodes `${HOME}/.claude/projects` — correctly, as the Claude adapter). The gap is honestly labeled "❌ planned" in README:340, so the DOC is exempt; the finding is that a peer capability exists for exactly one harness with no tracked plan file (positive probe: no `docs/superpowers/plans/*index*` for Copilot). Fix options for the executor: (a) extend index-session to walk `~/.copilot/session-state/*/events.jsonl` through the existing `transcript.py` parser into the same schema, or (b) replace "planned" with "not planned" if it isn't. Either resolves the claim/reality tension; (a) is the neutrality fix.
- **A2 (LOW)** VS Code sessions are not a telemetry source for Coach rules (telemetry.py reads Claude transcripts + Copilot store; VS Code transcripts parsed only for review). Coach docs describe sources as "the harnesses' own stores" without listing which. Fix: one sentence in docs/coach-integration.md §data-sources naming VS Code as not-a-source and why (its transcripts carry no usage/cost telemetry — verify reason at fix time).
- **A3 (LOW)** schema comment (= S1) claims Claude-only sessions; keep in sync with whichever A1 option is taken.

## Remediation summary

Work packages, in execution order (independent unless noted):

### WP1 — Symmetric absence guard (HIGH) [T1]
- New: `tests/test-copilot-absent.sh` — fake `claude` on PATH, no `copilot`, no `~/.copilot`; run scripts/session-review.sh end to end (use tests/lib/wait-for-review.sh), assert persistence + zero copilot references; header cites test-vscode-session-review.sh:110-129 for the VS Code claude-fallback coverage.
- Touch: tests/test-copilot-absent.sh (new), CLAUDE.md:17-19 (name both guards).

### WP2 — De-Claude the shared prompts and the author constant (HIGH) [P1, P2, P3, N6]
- prompts/curator-review.md:1 — neutral curator identity.
- Neutral `author` literal (e.g. `agent-review`), old `claude-code-review` accepted on read for one release: prompts/authoring-standards.md:68,82,145; config/claude-md-snippet.md:104; grep `claude-code-review` repo-wide at fix time for any validator/reviewer-prompt emitters.
- prompts/authoring-standards.md:112 — harness-neutral tool-naming rule.

### WP3 — Curator env-var migration (MEDIUM) [N1]
- Add `SL_CURATOR_IDLE_GATE` / `SL_CURATOR_LLM_PASS` as primary in scripts/curator-run.sh:41-42 with one-release CLAUDE_ shims (pattern: scripts/skill-lifecycle.py:88-105); update tests/test-store-lock-writers.py:282, README config table (add the two rows), scripts/curator-run.sh:16-17 usage comment, and :4 scheduler comment [L1].

### WP4 — Health parity for VS Code (MEDIUM) [T3]
- scripts/self-learning-health.sh: add "Hook Registration (VS Code Copilot Chat)" WARN-level section modeled on doctor.sh:326-347; a matching check in tests/test-health-* if the suite pins section names.

### WP5 — Copilot indexing decision (MEDIUM) [A1, S1, A3, R1]
- Either implement Copilot indexing (extend index-session via transcript.py into the same schema, update README:340 to ✅ and schema comment) or amend "planned" to a truthful status. Update schema/session-search-schema.sql:19 comment in the same commit either way.

### WP6 — Doc polish (LOW batch) [R2, R3, R4, R5, R8/N5, C2, A2, T4]
- README: per-harness publication-check snippet (:359-363); doctor line for Windows quick start (:30); requirements wording (:46); optional hooks-section lead-in (:134).
- Rename config/claude-md-snippet.md → neutral name + README:596 (grep referencing code first; N5).
- CLAUDE.md sandbox recipe: one Git-Bash-on-Windows line.
- docs/coach-integration.md: name VS Code as a non-source with reason.

### Explicitly NOT to change (EXEMPT ledger)
- Historical records: docs/research/**, docs/superpowers/** (dated plans/handoffs/spike), docs/verification-log.md, docs/project-creation-plan.md, docs/upstream-audit-2026-07-30.md.
- Honest disclosures: all "Linux-only measured" / "never observed firing" rows, Windows TOCTOU residual, WSL guard caveat, platform-coverage figures.
- Deliberate deprecation shims: CLAUDE_REVIEW_ENABLED, CLAUDE_LEARNED_SKILLS_DIR, CLAUDE_SKILL_{STALE,ARCHIVE}_DAYS (but pin the removal release somewhere).
- Adapter-specific code: telemetry.py CLAUDE_* parser constants, index-session.sh's ~/.claude/projects (it IS the Claude adapter), doctor/health Claude-report blocks, harness-owned config locations (~/.claude/settings.json, ~/.copilot/hooks).
- Constraint: local folder name `claude-self-learning` (CLAUDE.md forbids rename — worktree link).
