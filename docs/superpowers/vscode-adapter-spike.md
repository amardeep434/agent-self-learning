# VS Code Copilot Chat adapter — feasibility findings and spike results

**Status: SHIPPED 2026-07-28.** The spike passed on VS Code 1.130.0 /
GitHub.copilot-chat 0.58.0 (Linux) — no VS Code extension required, no new
parsing required, no fallback required (§3) — and the adapter was implemented
in the same session. What exists is listed in §5; what is still unmeasured is
in §6, and the answer is "everything except Linux".

Written 2026-07-28. This file is the tracker for the third-peer adapter that
`README.md` and `CLAUDE.md` used to declare as "(planned)" and the 2026-07-25 plan
deferred under "Out of Scope (**subsequent plans**)". Until this file existed, that
work was described as "tracked separately" while nothing tracked it.

---

## 1. What is established, with evidence

Everything here was verified against primary sources or measured on a real machine.
Nothing in this section is inference.

| # | Finding | Evidence |
|---|---|---|
| 1 | VS Code Copilot Chat ships a hook system that runs `type: "command"` hooks — **no extension of ours required** | <https://code.visualstudio.com/docs/copilot/customization/hooks> |
| 2 | Default `chat.hookFilesLocations` includes **`~/.claude/settings.json`** | same doc: `{".github/hooks": true, ".claude/settings.local.json": true, ".claude/settings.json": true, "~/.claude/settings.json": true}` |
| 3 | A `Stop` event exists ("Agent session ends"). There is **no** `SessionEnd` event | same doc's event table |
| 4 | VS Code parses Claude Code's hook format but **ignores matcher values** — hooks run on every tool invocation | same doc: "Currently, VS Code ignores matcher values" |
| 5 | The payload carries `session_id`, `hook_event_name`, `cwd`, and `transcript_path` | same doc |
| 6 | The transcript format is **explicitly not a stable API**: "The transcript file format is not a stable hook API and may change in future VS Code releases" | same doc |
| 7 | The whole feature is **Preview** — "configuration format and behavior might change" | same doc |
| 8 | Hook transcripts exist on disk here: `~/.config/Code/User/workspaceStorage/<ws>/GitHub.copilot-chat/transcripts/<id>.jsonl` | measured: 19 files |
| 9 | **Our existing parser reads them unmodified.** `transcript.summarize_events` over all 19: **17 yielded ≥1 message**, largest 703 events → 94 messages | measured |
| 10 | Upstream Coach's VS Code parser is `parser-vscode.ts` (reads `workspaceStorage`), **not** `parser-vscode-cli.ts` — that one is Copilot CLI's | `parser-vscode-cli.ts:6` header; `parser-vscode.ts:28` `findVsCodeDirs` |

**Consequence of finding 2, which is the most important line in this file.**
`install.sh` tells users to merge our hooks into `~/.claude/settings.json`. That file is
a *default VS Code hook source*. So registering our Claude Code hooks also registers
them inside VS Code — a free third harness, or an unreviewed surprise, depending on
whether it was a decision. It was made a decision: see §4, THE TRAP.

## 2. Why not a VS Code extension

There is no public API for an extension to observe native Copilot Chat conversation
lifecycle (<https://github.com/microsoft/vscode/issues/310951> is an open request for
one). An extension would have to subscribe to an event that does not exist. The hook
route needs a JSON file and no packaging, no `.vsix`, no Marketplace step.

The existing Coach fork (`amardeep434/AI-Engineering-Coach`, branch
`feature/auto-export`) *is* a VS Code extension, but it is not a useful base: it reads
`chatSessions/` after the fact for analytics and exposes no session-end signal. Building
on it would inherit an unverified hand-maintained fork to solve what a JSON file solves
natively. (Separately: `README.md` points Route B at `<org>/ai-engineering-coach-fork`,
which does not resolve. The real fork is the one named above.)

## 3. The spike — RUN, and what it measured

Run 2026-07-28 on VS Code 1.130.0 / `GitHub.copilot-chat` 0.58.0, Linux, in a scratch
`/tmp/vsspike` workspace using `.github/hooks/` (deliberately **not**
`~/.claude/settings.json`, so a probe could not leak into the real Claude Code config).
Two runs: three prompts in one agent-mode session, then one prompt in a brand-new
ask-only session.

| # | Question | Result | Consequence |
|---|---|---|---|
| 1 | Do hooks fire? | **YES** — 9 invocations in run 1, 2 in run 2 | The route is live |
| 2 | stdin or argv? | **stdin JSON on 11/11; argv empty on 11/11** | `scripts/lib/hook-input.sh` works unchanged |
| 3 | `Stop` per turn or per session? | **PER TURN** — 3 prompts produced 3 `Stop`s. Order was `UserPromptSubmit → PostToolUse → Stop` per turn | Needs the same turn-count gate Claude Code uses; `session-review.sh` already has it (`SL_REVIEW_MIN_TURNS`) |
| 4 | Is `transcript_path` present, and does the file exist yet? | **Present and EXISTS on 11/11.** It also grows between hooks in the same turn (524 → 1159 bytes) | No path discovery, no wait-for-file race |
| 5 | Does our parser read a LIVE file? | **YES, unmodified.** Run 1: 28 events → 8 messages. Run 2: 5 events → 2 messages. `unknown_shapes={}` both times | `summarize_events` is the whole session source; the C6 drift canary is clean on real VS Code data |
| 6 | Do ask-only sessions produce a transcript? | **YES.** A brand-new session with one no-tool prompt created a new transcript file (20 → 21) and fired `UserPromptSubmit → Stop` with **no** `PostToolUse` | **The `chatSessions/*.jsonl` fallback is NOT needed.** This was the main risk and it is retired |

Run-1 event mix in the produced transcript: `session.start` 1, `user.message` 3,
`assistant.turn_start`/`assistant.message`/`assistant.turn_end` 6 each,
`tool.execution_start`/`tool.execution_complete` 3 each — i.e. the same Copilot-CLI
event vocabulary `transcript.py` already speaks.

The original protocol, kept because it is the procedure to re-run on another platform:

Generate the probe kit and open the scratch workspace:

```bash
mkdir -p /tmp/vsspike/.github/hooks
cat > /tmp/vsspike/.github/hooks/probe.json <<'JSON'
{"hooks":{"Stop":[{"type":"command","command":"/tmp/vsspike/probe.sh","timeout":15}],
          "PostToolUse":[{"type":"command","command":"/tmp/vsspike/probe.sh","timeout":15}]}}
JSON
cat > /tmp/vsspike/probe.sh <<'SH'
#!/usr/bin/env bash
{ printf '=== %s event-argv:[%s]\n' "$(date -Is)" "$*"; cat; printf '\n'; } >> /tmp/vsspike/probe.log
SH
chmod +x /tmp/vsspike/probe.sh
code /tmp/vsspike
```

Deliberately uses `.github/hooks/`, **not** `~/.claude/settings.json`, so the probe
cannot leak into your real Claude Code config.

Then, in that window, send **three separate agent-mode prompts**, at least one of which
edits a file, and one of which is a plain question with no tool use.

| # | Check | Command | What it decides |
|---|---|---|---|
| 1 | Did anything fire? | `cat /tmp/vsspike/probe.log` | If empty, the whole hook route is dead and nothing below matters |
| 2 | Payload on stdin or argv? | look at the log lines | Our `hook-input.sh` assumes stdin JSON |
| 3 | `Stop` per turn or per session? | `grep -c '"hook_event_name":"Stop"' /tmp/vsspike/probe.log` | 3 ⇒ per turn; the existing `SL_REVIEW_MIN_TURNS` gate already handles it |
| 4 | Is `transcript_path` present, and does the file exist when the hook runs? | `grep -o '"transcript_path":"[^"]*"' /tmp/vsspike/probe.log` then `ls -l` it | Docs mark it optional; absence means we must discover the path ourselves |
| 5 | Does our parser handle the real file? | `python3 -c "import sys;sys.path.insert(0,'scripts/lib');import transcript as T;from pathlib import Path;r=T.summarize_events(Path('<path>'));print(r)"` | Expected to work — measured on 19 stored transcripts, but never on one produced live |
| 6 | Does a no-tool ask-mode turn produce a transcript at all? | check whether a new file appeared under `transcripts/` | If not, we need the `chatSessions/*.jsonl` fallback (~60 lines, upstream has the algorithm) |
| 7 | Are our hooks already live in VS Code? | `grep -c 'self-learning\|session-review\|turn-counter' ~/.claude/settings.json` | Non-zero ⇒ we are already running there unreviewed (see §1) |
| 8 | Hook latency | time the probe end to end | Our budget is <100 ms; VS Code's default timeout is 30 s |

## 4. THE TRAP, and the decision taken

Finding 2 is not a footnote, it is the design constraint. VS Code's *default*
`chat.hookFilesLocations` includes `~/.claude/settings.json` — the exact file
`install.sh` tells users to merge the Claude Code hooks into. So the moment a
user completes the Claude Code registration step, **VS Code also runs
`scripts/session-review.sh`**, handing it a VS Code `transcript_path`.

Three things were checked before choosing, because the obvious escapes do not
exist:

1. **It is not caused by the Claude Code VS Code extension.**
   `chat.hookFilesLocations` appears 3× in VS Code's core bundle
   (`resources/app/out/vs/workbench/workbench.desktop.main.js`) and 0× under
   `~/.vscode/extensions/anthropic.claude-code-*`. It is Copilot Chat's own
   compatibility import of Claude's config format, and the collision exists on
   a machine with no Claude extension installed.
2. **The two hook payloads are indistinguishable.** Across the 9 recorded VS
   Code payloads the fields are `cwd`, `hook_event_name`, `session_id`,
   `timestamp`, `transcript_path` (+ `prompt` / `stop_hook_active` /
   `tool_*`) — Claude Code's own field names, and the same `"Stop"` event
   name. `timestamp` is *probably* absent from a Claude Code Stop payload, but
   that is a negative, undocumented signal on both sides and it identifies the
   CALLER when what the parser needs to know is what the FILE is. Rejected.
3. **Path-shape guessing (`GitHub.copilot-chat/transcripts` in the path) is a
   name guess, not a probe.** Rejected on this project's standing rule.

**Decision: (a) — detect the format from the transcript's own content, with (b)
documented as an option rather than as the mechanism.**

The discriminator is a dotted top-level `type`. It is not a heuristic here; it
separates the two real corpora on this machine perfectly, both ways:

| Corpus | Files | Typed lines | Dotted `type` | Bare-word `type` |
|--------|-------|-------------|---------------|------------------|
| `~/.claude/projects/*/*.jsonl` | 330 | 82,444 | **0** | 82,444 (17 distinct values) |
| `workspaceStorage/*/GitHub.copilot-chat/transcripts/*.jsonl` | 21 | 2,573 | **2,573** | **0** |

`detect_transcript_format()` classified 351/351 of those files correctly.

What it fixed, MEASURED against the committed code before the change: a VS Code
transcript fed to `transcript.py --harness claude` yields **0 messages**, i.e.
`OUTCOME_FAILURE` — an empty digest, a `persist-failures.log` line, and
`session-review.sh` spawning the reviewer anyway. Because VS Code's `Stop` is
per TURN, that is one paid contentless model call **and** one failure-log line
**per user turn**, which both wastes money and trains the user to ignore the
one channel a genuinely broken review can reach.

`session-review.sh` therefore now calls `transcript.py --harness auto`.
Registering both hook sources still produces two reviews per turn, so
`install.sh` and `README.md` say so and give the one-line opt-out
(`"~/.claude/settings.json": false`) — as an *option*, since
`chat.hookFilesLocations` is user-configurable and correctness must not depend
on a user having edited it.

## 5. What was built

Nothing in the write path changed — `persist-proposal.py`, `paths.py`,
`store_lock.py` and the skill layout are harness-neutral already, which is
exactly what that design was for.

- `scripts/lib/transcript.py` — `build_vscode_session_digest` (Claude's
  resolution, Copilot's `summarize_events` parser),
  `detect_transcript_format`, `build_path_session_digest`, and
  `--harness vscode|auto` plus `--component` on the CLI. No new parsing.
- `scripts/lib/review-common.sh` — **new.** The OUTPUT CONTRACT, the
  transcript section, the Coach-signals section and the detached-pipeline
  launcher, extracted from the two existing review scripts (they were
  byte-identical; verified with `diff` before the move) rather than pasted a
  third time. Behaviour preservation was proved by capturing the real prompt
  each script builds, before and after, through a fake CLI shim: **byte-identical
  on both paths**, with `test-session-review.sh` and
  `test-copilot-session-review.sh` unchanged and green.
- `scripts/vscode-session-review.sh` — the `Stop` hook. Turn-gated, detaches
  the same pipeline, picks a reviewer CLI (`SL_VSCODE_REVIEWER`, else
  `copilot` then `claude`), and differs from `session-review.sh` in two
  deliberate places, both because `Stop` is per turn: it does **not** spawn a
  reviewer when no digest could be built, and it **resets**
  `total_turns_this_session` so the gate re-arms.
- `config/vscode-hooks.json` — Claude's nested schema (VS Code parses it),
  `timeout` in seconds, `__SL_SCRIPTS_DIR__` placeholder. Registers
  `turn-counter.sh` on `PostToolUse` — required, not optional, since it is the
  only thing feeding the per-turn gate — and deliberately does **not** register
  `index-session.sh`, which reads Claude Code's own `~/.claude/projects`.
- `install.sh` / `uninstall.sh` — Step 4c renders, writes and prints it, with
  the trap warning; uninstall removes the rendered file and names the one
  setting it cannot edit back out.
- Tests — `test-vscode-hooks-json.sh`, `test-vscode-session-review.sh`, VS Code
  fixtures and a `TestDetectTranscriptFormat` class in `test-transcript.py`, a
  trap regression case in `test-session-review.sh`, and a per-adapter guard
  added to `test-review-launch-lint.py` (which had been blind to the new
  suite's launches while still reporting success).

## 6. Open questions — what is STILL not settled

Answered by the spike and no longer open: `Stop` cadence (per turn), ask-only
transcripts (they exist), stdin delivery, `transcript_path` availability, and
whether our parser copes (it does, unmodified). What remains:

- **No real VS Code hook has ever invoked our scripts.** The spike drove a
  throwaway probe script; `vscode-session-review.sh` has only run under its
  test suite against fake reviewer CLIs, and no real model call has been made
  on this path. This is the same residual the Copilot adapter carried, and it
  needs ordinary day-to-day use to clear.
- Windows and macOS: zero evidence for either hook registration or
  `transcript_path` form. This is precisely where the Copilot CLI adapter broke
  before (MSYS path forms).
- VS Code Server / remote and Insiders layouts: untested; upstream handles
  `~/.vscode-server/data/User/workspaceStorage`.
- Ask-only VS Code sessions are never reviewed. They produce no `PostToolUse`
  (measured), so the turn counter never advances and the gate never opens.
  Accepted: it errs toward under-reviewing rather than toward per-turn spend.
- The transcript format is a documented-unstable dependency (finding 6). The C6
  drift canary covers it from day one (`unknown_shapes` in `summarize_events`,
  asserted in `TestVsCodeSessionDigest`), which turns a format change into a
  `persist-failures.log` line rather than a silently halved digest. It cannot
  prevent one.
