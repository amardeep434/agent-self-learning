# VS Code Copilot Chat adapter — feasibility findings and spike protocol

**Status: feasible, no VS Code extension required. Blocked on one human-run spike.**
Written 2026-07-28. This file is the tracker for the third-peer adapter that
`README.md` and `CLAUDE.md` declare as "(planned)" and the 2026-07-25 plan deferred
under "Out of Scope (**subsequent plans**)". Until this file existed, that work was
described as "tracked separately" while nothing tracked it.

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
whether it was a decision. On the machine this was written on, `~/.claude/settings.json`
contains hooks but **zero** mentions of ours, so nothing is live yet. Decide deliberately
before `D7` (registering the Claude Code hooks) happens.

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

## 3. The spike — what a human must run

Everything about hook *execution* below is currently read from docs and shipped bytes.
**Nobody has observed a VS Code hook fire.** These checks are ordered so each one's
failure makes the later ones moot.

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

## 4. Scope, if the spike passes

Small adapter. Nothing in the write path changes — `persist-proposal.py`, `paths.py`,
`store_lock.py` and the skill layout are all harness-neutral already, which is exactly
what that design was for.

- `scripts/lib/transcript.py` — a `build_vscode_session_digest`, which is the Claude one
  with `summarize_events` swapped in for `summarize_claude_events`. ~30 lines, no new
  parsing (finding 9).
- `scripts/vscode-session-review.sh` — near-copy of `session-review.sh`; can source
  `scripts/lib/hook-input.sh` unchanged. **This is the third near-copy of the same
  prompt-building code; extract the shared builder rather than paste a third time.**
- `config/vscode-hooks.json` — same `__SL_SCRIPTS_DIR__` placeholder convention, PascalCase
  events, Claude-shaped per-command keys (`command`/`timeout` in seconds), not Copilot
  CLI's `bash`/`powershell`/`timeoutSec`.
- `install.sh` — one more render+print step, plus the `~/.claude/settings.json` decision.
- Tests — mirrors of `test-claude-hooks-json.sh`, a fixture in `test-transcript.py`, and
  `test-vscode-session-review.sh`. `tests/run-all.sh` globs, so no count to update.

## 5. Open questions — do not treat these as settled

- Whether `Stop` fires per turn or per session. Docs say "Agent session ends"; the
  shipped UI string is "When agent execution stops" and the call site is
  `ToolCallingLoop.executeStopHook`. **Inferred, not measured** — spike check 3.
- Whether ask-mode / no-tool turns produce a transcript. Transcript writing is gated on
  `hasHooksEnabled` inside `ToolCallingLoop`; whether a non-tool turn reaches it is
  unknown — spike check 6.
- Windows and macOS: zero evidence for either hook registration or `transcript_path`
  form. This is precisely where the Copilot CLI adapter broke before (MSYS path forms).
- VS Code Server / remote and Insiders layouts: untested; upstream handles
  `~/.vscode-server/data/User/workspaceStorage`.
- The transcript format is a documented-unstable dependency (finding 6). That is a
  *worse* footing than Copilot CLI's `events.jsonl`, which is merely undocumented. The
  C6 drift canary now covers this class for the formats we already parse; a VS Code
  source should be wired into the same canary from day one.
