# agent-self-learning

**Your coding agent learns from every session — and you never have to curate it.**

A cross-harness self-learning system adapted from NousResearch's Hermes Agent architecture.
It serves **Claude Code**, **GitHub Copilot CLI** and **VS Code Copilot Chat** as peers:
Claude Code is one adapter among them, and no shared code path — storage, review pipeline,
skill/memory schema — may depend on it.

Everything runs in the background via hooks and detached subagents, writing to one shared,
vendor-neutral store on disk that persists across sessions and is loaded as a frozen
snapshot at session start.

| | |
|---|---|
| 🧠 **Memory** | A bounded `MEMORY.md` (agent notes) and `USER.md` (user profile), rewritten by a background reviewer and threat-scanned. Memory is **never truncated** on the way into a session — growth is bounded on the *write* side and an oversized file is reported, not silently cut. |
| 📚 **Skills** | A file-backed library of reusable knowledge with usage telemetry and lifecycle states (active / stale / archived). |
| 🧹 **Curator** | A periodic pass that consolidates narrow skills into class-level umbrellas and archives unused ones. |
| 🔎 **Session search** | A SQLite index of past sessions, full-text (FTS5) where the local build supports it. |
| 📈 **Coach signals** | Optional: [Microsoft's AI Engineering Coach](https://github.com/microsoft/AI-Engineering-Coach) anti-pattern rules steer what the reviewer looks for. |

---

## Quick start

```bash
git clone <this-repo> && cd agent-self-learning
bash install.sh --dry-run      # see exactly what it would do
bash install.sh
bash scripts/doctor.sh         # confirm paths, writability, detected harnesses
```

**Windows (PowerShell, with Git for Windows installed):**

```powershell
git clone <this-repo>; cd agent-self-learning
.\install.ps1 --dry-run        # flags pass straight through to install.sh
.\install.ps1
```

Then [register the hooks](#registering-hooks) for whichever harnesses you use. Nothing
happens until you do — the installer deliberately does not edit a harness's own config
files beyond Copilot CLI's dedicated hooks directory.

<details>
<summary><strong>Requirements</strong> (at least one of Claude Code / Copilot CLI must be installed)</summary>

| Dependency | Needed for | Version | Windows notes |
|------------|-----------|---------|---------------|
| bash | all scripts | 4.0+ | via Git for Windows (Git Bash) or WSL |
| jq | hook payload + settings/JSON handling | 1.6+ | `winget install jqlang.jq` |
| python3 | injector, coach signals, session indexing and search (incl. its bundled `sqlite3` module) | 3.9+, stdlib only — 3.9 is the CI floor; **3.8 is untested** | `winget install Python.Python.3.12` |
| sqlite3 (CLI, optional) | manual DB inspection; `self-learning-health.sh`'s database check (degrades to a warning, not a failure, if absent) | any | bundled with Git for Windows |
| Claude Code | Claude adapter (optional) | current | — |
| GitHub Copilot CLI | Copilot adapter (optional) | current, authenticated | PowerShell 7+ for its hooks |
| VS Code + GitHub Copilot Chat | VS Code adapter (optional) | measured on VS Code 1.130.0 / `GitHub.copilot-chat` 0.58.0 — no lower bound has been tested | untested on Windows/macOS and on VS Code Server/remote — **Linux only so far** |
| gh CLI | vendoring Coach rules, fork maintenance | 2.40+ | `winget install GitHub.cli` |
| Node.js + npm | building the Coach fork VSIX (Route B only) | Node 22+ | `winget install OpenJS.NodeJS` |

The VS Code adapter is **not self-sufficient**: VS Code Copilot Chat has no headless CLI,
so the review it triggers runs in `copilot` or `claude` (see `SL_VSCODE_REVIEWER`).

</details>

<details>
<summary><strong>Why the PowerShell wrappers refuse some <code>bash</code> installs</strong></summary>

`install.ps1`/`uninstall.ps1` are parse-checked and behaviourally tested on every push
(GitHub's ubuntu runners ship `pwsh`). They check that the `bash` they found can actually
see this repository before delegating to it — a `test -f` probe on the exact script path,
never a filename match.

If the first `bash` on your PATH is WSL's launcher (`C:\Windows\System32\bash.exe`), it
runs inside the WSL filesystem, where this directory is `/mnt/c/...` and `$HOME` is the
WSL user's, so an install through it would land somewhere you are not looking. The
wrappers refuse with an explanation instead. To install for WSL, run `bash install.sh`
inside WSL deliberately.

</details>

---

## How it works

```
SESSION START
    |
    v
+-------------------+     +--------------------+     +------------------+
| Load frozen       |     | MEMORY.md (no cap) |     | USER.md (1375ch) |
| snapshots from    |<----| learned-skills/    |     | .usage.json      |
| disk into prompt  |     | sessions/search.db |     |                  |
+--------+----------+     +--------------------+     +------------------+
         |
         v
+--------+----------+
| Normal            |     PostToolUse hook
| conversation      |---> turn-counter.sh
| (user <-> agent)  |     (increments counter)
+--------+----------+
         |
         | every N turns (default 10)
         v
+--------+----------+
| Background Review |     Detached headless reviewer (Claude Code subagent
| - Memory review   |---> or Copilot CLI, per harness) proposes a single JSON
| - Skill review    |     object on stdout; scripts/persist-proposal.py
| - Combined review |     validates it and performs every write, confined
+--------+----------+     to the resolved store
         |
         v
+--------+----------+
| Session End       |     Stop hook / sessionEnd hook
| - Final review    |---> session-review.sh
| - Index session   |---> index-session.sh  (SQLite, FTS5 when available)
+--------+----------+
         |
         v (periodic, every 7 days)
+--------+----------+
| Curator           |     Consolidates narrow skills into class-level
| - Lifecycle prune |---> umbrellas; archives stale/unused skills
| - Skill merge     |
+-------------------+
```

**The reviewer cannot write.** It proposes; `scripts/persist-proposal.py` validates and
performs every write, confined to the resolved store. Claude Code's reviewer is spawned
with `--allowedTools Read,Glob,Grep --disallowedTools Write,Edit,NotebookEdit`; Copilot's
with `--allow-tool read` only. See [Bounding reviewer cost](#bounding-reviewer-cost).

---

## Registering hooks

### Claude Code

`config/settings-hooks.json` is a **template, not a file to merge as-is**: it carries a
`__SL_SCRIPTS_DIR__` placeholder that `install.sh` substitutes with the resolved store's
`scripts` directory. Merge the **rendered** copy — which `install.sh` both prints and
writes to `<store>/settings-hooks.json` — into `~/.claude/settings.json`. Merging the raw
template registers hooks that invoke a literal `__SL_SCRIPTS_DIR__` path and never fire.

To render it yourself without re-running the installer:

```bash
printf '%s' "$(python3 scripts/lib/paths.py get scripts)" \
    | python3 scripts/lib/render-template.py config/settings-hooks.json
```

This is the same renderer `install.sh` calls, so you get exactly the bytes it would have
written. The same command renders `config/copilot-hooks.json` and `config/vscode-hooks.json`.

> **Two details that are load-bearing, not stylistic.**
> The renderer replaced a one-liner substitution that silently corrupted any store path
> containing `&`, `\` or `|` — see `scripts/lib/render-template.py` for what each one did.
> And the scripts directory is **piped in** rather than passed as an argument: on Git Bash,
> MSYS rewrites POSIX-looking *arguments* to native Windows form as they cross into
> `python3`, which would change the path spelling written into your hook file. Keep the pipe.

`~/.claude/settings.json` is Claude Code's own config file, so *that* location is
deliberately Claude-specific; the **script paths it invokes** are not, and must point at
the vendor-neutral store.

### GitHub Copilot CLI

Installed automatically to `~/.copilot/hooks/self-learning.json` when `~/.copilot` exists.
Nothing further to do.

### VS Code Copilot Chat

`install.sh` renders `config/vscode-hooks.json` to `<store>/vscode-hooks.json` and prints
the one setting that registers it:

```jsonc
"chat.hookFilesLocations": {
  "/path/to/store/vscode-hooks.json": true
}
```

It does **not** edit your VS Code settings.json — an installer writing into an editor's
user settings is not something this project does.

> ⚠️ **Read this before registering anything.** VS Code's *default*
> `chat.hookFilesLocations` already includes `~/.claude/settings.json`
> ([docs](https://code.visualstudio.com/docs/copilot/customization/hooks)) — the same file
> the Claude Code step tells you to merge into. So completing the Claude Code step **also
> registers these hooks inside VS Code**, with no action from you and no Claude extension
> involved (`chat.hookFilesLocations` lives in VS Code's own core bundle).
>
> That is handled rather than assumed away: `session-review.sh` and
> `vscode-session-review.sh` both detect which transcript format they were handed by
> reading the file, because the two hook payloads are otherwise identical. But registering
> **both** sources means two reviews per VS Code turn, so pick one:
>
> - **Claude Code hooks only** — nothing more to do; VS Code reuses them, and a VS Code
>   transcript reaching `session-review.sh` is parsed correctly.
> - **The VS Code file** — add it as above, and set `"~/.claude/settings.json": false` in
>   the same setting.

VS Code registration deliberately does **not** include `index-session.sh`: that indexes
Claude Code's own `~/.claude/projects` directory and has nothing to say about a VS Code
session. `turn-counter.sh` **is** registered on `PostToolUse`, and it is load-bearing
here — VS Code's `Stop` hook fires **per turn**, not per session (measured: 3 prompts
produced 3 `Stop`s), so the turn gate is the only thing between this adapter and one paid
model call per user turn.

---

## Where everything lives

All framework state — memory, learned skills, session index, logs, installed scripts —
lives under one vendor-neutral store resolved by `scripts/lib/paths.py` and shared by
every bash script via `scripts/lib/config.sh`. **No default points inside `~/.claude`.**
That was the previous default, and it is exactly what broke Copilot CLI persistence:
Copilot's path allow-list refuses writes outside its own namespace, so review output
written to `~/.claude` was silently discarded.

Resolution order, first hit wins:

1. `$AGENT_LEARNING_HOME` — explicit override, mainly for testing/debugging
2. `$XDG_DATA_HOME/agent-learning`
3. Windows only: `%LOCALAPPDATA%\agent-learning`
4. `~/.local/share/agent-learning` (Linux and macOS default)

```bash
python3 scripts/lib/paths.py all          # every resolved path
python3 scripts/lib/paths.py get skills   # one of them
```

Keys: `home`, `state`, `skills` (`learned-skills/`), `memory`, `logs`, `sessions_db`
(`sessions/search.db`), `config_file` (`self-learning.conf`), `scripts`.

**Harness-owned config files are a deliberate exception** and stay where each harness owns
them: Claude Code's `~/.claude/settings.json` and Copilot CLI's
`~/.copilot/hooks/self-learning.json` are not moved into the store — only the script paths
those configs invoke are resolved through it. The VS Code hook file is the exception to
the exception: it is rendered *into* the store, because VS Code takes hook sources from a
settings key rather than from a fixed path, so there is no harness-owned location to write
it to.

<details>
<summary><strong>Concurrent writes are serialised</strong> — why, and by what</summary>

Both harnesses can fire a review hook at nearly the same moment, and the review pipeline
is detached by design, so two `persist-proposal.py` processes racing each other is
ordinary operation, not an edge case. Every write transaction (read existing content →
merge → stage → rename) therefore runs under one whole-store exclusive lock at
`<state>/persist.lock` (`scripts/lib/store_lock.py`). Without it, concurrent appends to
`MEMORY.md` — and concurrent updates to `learned-skills/.usage.json` — silently overwrote
each other **while every writer reported success**.

Every writer takes the same lock: `persist-proposal.py` for its whole plan-and-write
transaction, `skill-lifecycle.py` for its whole pass, and `curator-run.sh` for its pre-run
backup (so that backup is a point-in-time snapshot rather than a mix of before and after).
The curator releases the lock before invoking `skill-lifecycle.py`, which takes it in its
own process — short spans, deliberately, because one long hold across a whole curator
sweep would make a session-end review wait behind it.

The lock is `flock` on POSIX and `msvcrt.locking` on Windows, each chosen by a **functional
probe rather than a platform name**, with an `O_CREAT|O_EXCL` lockfile as a last resort.
Both kernel-backed backends are released by the OS when the holding process dies, so a
crashed review cannot wedge the store; only the fallback needs (and has) age-based
stale-lock breaking. `doctor.sh` prints which backend is in force. Waiting is bounded —
default 20s, overridable with `SL_PERSIST_LOCK_TIMEOUT` — and a timeout fails loudly: a
non-zero exit plus a `lock timeout` line in `persist-failures.log`.

Both kernel-backed backends are confirmed to *execute* in CI, not merely to exist — see
[platform coverage](docs/platform-coverage.md).

</details>

<details>
<summary><strong>Migrating from an older <code>~/.claude</code> install</strong></summary>

Nothing is moved automatically, on install or otherwise. If you have an older install that
wrote memory/skills under `~/.claude`, run `bash scripts/doctor.sh`: it detects a populated
`~/.claude/memory` or `~/.claude/learned-skills` and reports it under "legacy store"
without touching it. To migrate deliberately, copy the data yourself:

```bash
cp -r ~/.claude/memory ~/.claude/learned-skills "$(python3 scripts/lib/paths.py get home)/"
```

</details>

---

## Diagnostics: `scripts/doctor.sh`

```bash
bash scripts/doctor.sh            # any time
bash scripts/doctor.sh --strict   # also fail on a stale hook config (for CI)
```

It reports every resolved path and **which override produced it**; whether each is
actually writable (a real create+remove temp-file test, not a permission-bit guess);
which harnesses (`claude`, `copilot`, `code`) are detected and whether their hook configs
point at the current scripts directory (`fresh`) or a stale one (`stale`); whether a
legacy `~/.claude` store exists (detected, never touched); which write lock and which
writer are in force; and — most importantly — the contents of
`${SL_LOG_DIR}/persist-failures.log`.

> **That log deserves special attention.** The background review pipeline runs fully
> detached (`nohup … &`) so the calling hook can return immediately. This means a review
> that fails — bad model output, a validation rejection in `persist-proposal.py`, an
> attempted write outside the store — can **never surface as a non-zero hook exit code**.
> `doctor.sh` reading `persist-failures.log` is the only mechanism that replaces that
> missing signal.
>
> If you want to know whether background learning is actually persisting anything, run
> `doctor.sh`. **Do not infer health from "the hook didn't error."**

Doctor also distinguishes an **ABSENT** log ("never ran, or ran and never failed") from an
**EMPTY** one ("ran and recorded zero failures") — deleting the file asserts something
different from truncating it.

By default `doctor.sh` exits non-zero only for a non-writable resolved path or a non-empty
`persist-failures.log`; a `stale` hook is printed loudly but does not affect the exit code,
so a plain run can report `overall: HEALTHY` while a hook config still points at an old
scripts directory. `--strict` additionally fails on that — use it in CI or any wrapper
that gates on doctor's exit code. One exception applies in both modes: a detected legacy
`~/.claude` store is **never** fatal, because every machine upgraded from a
pre-vendor-neutral install would otherwise fail `doctor.sh` forever, training operators to
ignore its exit code entirely.

---

## Harness support

Only rows backed by a suite in `tests/run-all.sh` are marked supported.

| Capability | Claude Code | Copilot CLI | VS Code Copilot Chat |
|------------|-------------|-------------|----------------------|
| Learned memory + skills stores | ✅ | ✅ | ✅ |
| Learned memory injected at session start | ⚠️ wired, never observed firing | ⚠️ wired, never observed firing | ⚠️ wired, never observed firing |
| Learned skills published where the harness looks | ⚠️ wired, never observed firing | ⚠️ wired, never observed firing | — (reads `~/.claude`) |
| Session-end background review | ✅ `Stop` | ✅ `sessionEnd` | ✅ `Stop` — **per turn**, not per session |
| Mid-session turn counting | ✅ `PostToolUse` | ❌ not wired (deliberate — the session-end loop is the portable core) | ✅ `PostToolUse` — **required**, not optional, because `Stop` is per turn |
| Independent of Claude Code | — | ✅ `test-claude-absent.sh` runs the full Copilot path with no `claude` binary and no `~/.claude` | — |
| Session search indexing | ✅ (Claude JSONL) | ❌ planned | ❌ not wired — `index-session.sh` reads `~/.claude/projects` |
| Coach signals (Routes A/B) | ✅ | ✅ | ✅ |
| Live end-to-end, real session on disk | ✅ | ✅ 2026-07-25 / -26, real paid model call | ⚠️ **never** — no real VS Code hook has invoked our scripts |

> **On "wired, never observed firing".** Delivery exists as of 2026-07-30 and is exercised
> by 55 passing suites, but **no real hook has ever fired it** on Claude Code or VS Code.
> Every harness contract behind it was read out of shipped code and disassembly, not
> observed at runtime — the sole exception is Copilot CLI's, where the real
> `runtime.node` parser was invoked directly. So these rows stay ⚠️ deliberately: a green
> matrix is not evidence that a hook ran.
>
> Flip a row to ✅ only after observing it live, and prove it with a **byte count before
> and after** rather than the emptiness of a command's output — that mistake is this
> project's signature defect and has produced a false "verified clean" here before:
>
> ```bash
> # memory injection (Route B) — run a real session, then:
> tail -3 "$(python3 scripts/lib/paths.py all | sed -n 's/^logs=//p')/persist-failures.log"
> # skill publication (Route A):
> ls ~/.claude/skills/*/.self-learning-managed 2>/dev/null | wc -l
> ```
>
> Until 2026-07-30 there was a single row here reading `✅ | ✅ | ✅` for "AGENTS.md
> learned-context injection". It had never run once: **0 of 175** `AGENTS.md`/`CLAUDE.md`
> files under `$HOME` carried the marker. The 2026-07-22 plan specified the injector and
> its test but named no invoker, so the gap was in the spec rather than a regression —
> `git log --all -S "inject-agents-md.py" -- 'scripts/*.sh' install.sh 'config/*'` shows a
> caller never existed. See
> [`docs/upstream-audit-2026-07-30.md`](docs/upstream-audit-2026-07-30.md) for the evidence
> and [`docs/superpowers/plans/2026-07-30-learned-context-delivery.md`](docs/superpowers/plans/2026-07-30-learned-context-delivery.md)
> for the plan this implements.
| Windows | ✅ green, with skips | ✅ green, with skips | ⚠️ untested — suites run, no hook has ever fired |
| macOS | ✅ green | ✅ green | ⚠️ untested — same |

**CI results are per-OS**, not per-harness: the whole matrix cell passes or fails, so both
CLI columns necessarily show the same platform result. The matrix is
`{ubuntu, macos, windows}-latest × Python {3.9, 3.13}` — six cells.

> **Green ≠ equally covered.** A set of write-path security and shell tests skip on
> Windows, each gated on a probe that *verifies* the limitation rather than inferring it
> from the platform name. **[`docs/platform-coverage.md`](docs/platform-coverage.md)** has
> the per-suite breakdown, the real causes, and the commands to re-derive it — no run id
> is pinned as "current" anywhere, because every version of this file that pinned one went
> stale within hours.

Ask GitHub for the live state rather than reading it here:

```bash
gh run list --branch main
```

**Note on the VS Code column.** Every VS Code measurement behind this adapter was taken on
Linux, VS Code 1.130.0 / `GitHub.copilot-chat` 0.58.0. The suites
(`test-vscode-session-review.sh`, `test-vscode-hooks-json.sh`, VS Code fixtures in
`test-transcript.py`) run everywhere; the *harness* has been observed on one platform.

---

## Known residuals

Stated rather than quietly carried. None of these is a plan to fix; each is a limit a
reader should know before trusting the system further than it goes.

- **The TOCTOU hardening does not cover Windows.** `persist-proposal.py` anchors every
  write on a `dir_fd` with `O_NOFOLLOW`, which closes the resolve-then-open race. Both
  primitives are POSIX-only and the stdlib offers no Windows equivalent, so Windows falls
  back to the documented, weaker path-based writer. `doctor.sh` prints which writer is in
  force. Closing it would need a Windows-specific reimplementation outside the stdlib-only
  constraint.

- **The WSL-vs-Git-Bash PATH ambiguity is reasoned about but not CI-tested.** The logic is
  tested on ubuntu runners, which have `pwsh` but no WSL — so the *scenario* the guard
  defends against cannot be reproduced without a Windows PowerShell CI job, which does not
  exist. See [platform coverage](docs/platform-coverage.md).

- **`transcript.py` parses three third-party on-disk formats, none of them a stable API** —
  Copilot CLI's `session-state/<id>/events.jsonl`, Claude Code's
  `projects/<slug>/<id>.jsonl`, and VS Code Copilot Chat's
  `workspaceStorage/<ws>/GitHub.copilot-chat/transcripts/<id>.jsonl` (the third shares the
  first's event vocabulary, so it adds a pairing, not a parser). All three were
  reverse-engineered from real files; the first two are undocumented and unversioned, and
  the third is **worse** — VS Code documents it explicitly as *"not a stable hook API and
  may change in future VS Code releases"*, inside a feature marked Preview. An update on
  either side can break session digestion.

  The mitigation is that it **fails loudly**: every degraded outcome — file missing, zero
  parseable events, or events present but none matching the expected message shape (the
  exact signature of a renamed schema) — returns a named reason appended to
  `persist-failures.log`, which `doctor.sh` surfaces. It never yields a silently empty
  transcript, which is this project's signature failure mode. It cannot be made immune to
  a format change; it can only refuse to hide one.

- **VS Code adapter: the platform was measured live, our own loop was not.** On 2026-07-28
  (Linux, VS Code 1.130.0 / `GitHub.copilot-chat` 0.58.0) a throwaway probe established
  that hooks fire from a plain JSON file, the payload arrives as JSON on stdin (11/11,
  argv empty 11/11), `transcript_path` is present and already exists (11/11), `Stop` fires
  per turn (3 prompts → 3 `Stop`s), an ask-only turn still produces a transcript, and
  `summarize_events` read the live files unmodified. But `vscode-session-review.sh` itself
  has only run under `tests/test-vscode-session-review.sh` against **fake reviewer CLIs** —
  no real VS Code hook has invoked it and no real model call has been made on this path.
  Windows, macOS, VS Code Insiders and VS Code Server/remote
  (`~/.vscode-server/data/User/workspaceStorage`) are entirely unmeasured. Full spike
  record: [`docs/superpowers/vscode-adapter-spike.md`](docs/superpowers/vscode-adapter-spike.md).

- **Ask-only VS Code sessions are never reviewed.** They produce no `PostToolUse`
  (measured), so the turn counter never advances and the gate never opens. Accepted: it
  errs toward under-reviewing rather than toward per-turn spend.

- **The `~/.claude/settings.json` hook source is shared with VS Code, by VS Code's own
  default.** Registering the Claude Code hooks therefore also registers them in VS Code.
  The transcript format is detected from the file's content, so this is correct rather
  than damaging — but registering the VS Code hook file *as well* produces two reviews per
  VS Code turn. See [Registering hooks](#vs-code-copilot-chat).

- **No *human, multi-turn, interactive* Copilot session has fired the `sessionEnd` hook.**
  What *has* been verified, with real paid model calls: on 2026-07-25 the full pipeline ran
  end-to-end and the writer accepted a valid, well-formed **empty** proposal (correct —
  headless `copilot -p` has no session transcript), and the same output contract with a
  synthetic transcript persisted real content to `<store>/memory/MEMORY.md` in append mode,
  mode 0600, nothing written outside the store. On 2026-07-26, `copilot -s --allow-tool
  read -p …` produced a **real** session directory, the real installed `sessionEnd` hook
  fired, and the detached pipeline persisted 279 bytes of genuinely session-derived
  content. So Copilot's own transcript reaching the prompt **is** exercised. What remains
  is ordinary day-to-day use in the TUI, not engineering.

- **Session search implements one query shape, not four.** `scripts/lib/session_db.py`
  exposes `search` (FTS5 `MATCH`, ranked and stemmed, falling back to a substring `LIKE`
  when the local SQLite build lacks FTS5 — probed functionally at index time, never
  assumed from a platform name). The *scroll / read / browse* shapes described in
  `config/claude-md-snippet.md` are SQL patterns for an agent to run against the index by
  hand; there is no tool implementing them.

- **One of the 45 vendored Coach rules is not evaluated** (44 evaluate). `no-devcontainer`
  is genuinely unreachable — upstream's own `computeDevcontainerStats` filters to VS Code
  harnesses before reading any field of ours. Its skip reason cites an upstream file and
  line, and `tests/test-coach-rules-eval.py` fails the suite if a reason carries no
  checkable evidence. The history of that number — 11 → 24 → 42 → 44, every correction in
  the same direction, twelve skip reasons found to be false — is recorded in
  [`docs/coach-integration.md`](docs/coach-integration.md) because it is a failure mode,
  not an accident.

---

## Configuration reference

Settings live in the resolved store's `config_file` (`self-learning.conf`, shell syntax,
`VAR=value`) — see [Where everything lives](#where-everything-lives). It defaults to
`~/.local/share/agent-learning/self-learning.conf` and is **never** `~/.claude` by default.
Environment variables of the same name override the file.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SL_HOME` | resolved store root | Root for all state |
| `SL_REVIEW_ENABLED` | `true` | Enable/disable the background review pipeline |
| `SL_MEMORY_REVIEW_INTERVAL` | `10` | Turns between memory review signals |
| `SL_SKILL_REVIEW_INTERVAL` | `10` | Tool calls between skill review signals |
| `SL_REVIEW_MIN_TURNS` | `5` | Minimum session turns before a review runs |
| `SL_REVIEW_MAX_TURNS` | `16` | Turn cap for the spawned Claude Code reviewer (`--max-turns`) |
| `SL_COPILOT_REVIEW_MODEL` | (CLI default) | Model for Copilot reviews; use the cheapest available. Must match `^[A-Za-z0-9._-]+$` |
| `SL_COPILOT_MAX_AI_CREDITS` | `30` | Cost ceiling for Copilot reviews (`--max-ai-credits`). Integer, minimum 30; anything else is dropped with a reason on stderr. Set it **empty** to restore unlimited (amended 2026-07-31; see below) |
| `SL_VSCODE_REVIEWER` | (empty — auto) | Which CLI reviews a VS Code session: `copilot` or `claude`. See note below |
| `SL_PERSIST_LOCK_TIMEOUT` | `20` (seconds) | How long a writer waits for the store lock before failing loudly |
| `SL_MEMORY_INJECT_BUDGET` | `32768` (bytes) | Size at which `MEMORY.md` is **reported** as worth consolidating when injected at session start. Advisory only — memory is never truncated; exceeding it costs a line in `persist-failures.log`, not content. Roughly 4 bytes per token, so the default is ~8K tokens added per session start **and after every compaction** |
| `SL_MEMORY_NEAR_DUP_THRESHOLD` | `0.62` | Similarity at which an appended `MEMORY.md` line is **refused** as restating an existing one. `0` disables it. Exact repeats are refused separately. Never auto-merged — merging is a judgement about meaning, so the reviewer is told to consolidate with a `replace` entry instead |
| `SL_COACH_RULES_ENABLED` | `false` | Coach Route A (rule evaluation) |
| `SL_COACH_EXPORT_ENABLED` | `false` | Coach Route B (fork auto-export) |
| `SL_COACH_EXPORT_PATH` | `~/.aiec/summary-latest.json` | Route B input file |
| `SL_SKILLOPT_ENABLED` | `false` | Route C: SkillOpt skill optimization (opt-in) |
| `SL_SKILLOPT_REPO` | (empty) | Path to a microsoft/SkillOpt checkout. **Optional** when `skillopt-sleep` is on `PATH`; a checkout wins when both are present, matching upstream's own precedence |
| `SL_SKILLOPT_RUN_CONFIRMED` | `false` | Safety gate; the expensive `run` verb refuses until set true after a dry-run cost review |

`SL_VSCODE_REVIEWER`: VS Code Copilot Chat has no headless CLI of its own, so the review
has to run in one of the two this project already drives. Empty auto-detects, preferring
`copilot` (a VS Code Copilot Chat user has a Copilot entitlement by construction, and the
transcript being reviewed is Copilot's own). Anything outside that closed set is dropped
with a reason on stderr, never passed to argv. If neither CLI is on `PATH`, the hook
writes a named line to `persist-failures.log` rather than exiting 0 having done nothing.

### Bounding reviewer cost

The two harnesses bound the background reviewer differently, and the asymmetry is deliberate.

- **Claude Code** takes a hard turn cap: `--max-turns "$SL_REVIEW_MAX_TURNS"`, on by
  default at 16. It is also spawned with `--allowedTools Read,Glob,Grep --disallowedTools
  Write,Edit,NotebookEdit`, so the reviewer can read what it needs and cannot write
  anything.
- **GitHub Copilot CLI** has **no turn cap** for headless `-p` runs
  (`--max-autopilot-continues` is interactive-only). It does have `--max-ai-credits`,
  documented under `copilot help limits`, minimum 30 — and it is a *soft* cap: usage is
  known only after a response returns, so it bounds a runaway loop rather than any single
  call.

`SL_COPILOT_MAX_AI_CREDITS` **ships at 30** (the CLI's documented minimum). This was
amended on 2026-07-31 — it used to default to empty/unlimited, deliberately. The cost of
the amendment is real and is stated here rather than hidden: `copilot` errors on unknown
options, so on a Copilot CLI older than the release that added `--max-ai-credits` the
review now fails until you set `SL_COPILOT_MAX_AI_CREDITS=` (empty) in
`self-learning.conf`. That failure is **loud** — a named line in `persist-failures.log`
that `doctor.sh` surfaces — whereas unbounded spend in a detached pipeline was silent, and
a silent-failure pipeline with no spend ceiling is the worse of the two.

To confirm the flags against your own installed binaries at any time (no model calls, no
tokens): `bash tests/test-review-cli-flags.sh`.

### Deprecated

`CLAUDE_REVIEW_ENABLED` → use `SL_REVIEW_ENABLED`. The old name is honored for one release
for upgrade safety (its value is used with a deprecation warning on stderr if
`SL_REVIEW_ENABLED` is unset), but it will be removed.

---

## Uninstall

```bash
bash uninstall.sh                # removes EVERYTHING incl. learned data (asks first)
bash uninstall.sh --keep-data    # keep memory, skills, and the session index
bash uninstall.sh --yes          # non-interactive
```

Windows: `.\uninstall.ps1` (flags pass through unchanged). This also strips the
self-learning hooks from `~/.claude/settings.json` — a timestamped backup is written
first — and removes `~/.copilot/hooks/self-learning.json`.

---

## Design principles

1. **Best-effort, never block.** All self-learning runs in the background. The user's
   primary workflow is never interrupted.
2. **Fail loudly, never silently.** A degraded outcome gets a named reason in
   `persist-failures.log` that `doctor.sh` surfaces. A silently empty result is this
   project's signature failure mode and is treated as a defect.
3. **Frozen snapshot.** Memory and skills are snapshotted into the system prompt at
   session start. Mid-session writes update disk but do not mutate the running prompt
   (preserves prefix cache hits).
4. **Bounded storage.** Character limits on memory stores, lifecycle pruning on skills.
   The system cannot grow without bound.
5. **Class-level skills over narrow skills.** Prefer "Python testing patterns" over "how
   to mock datetime in pytest". The Curator enforces this via consolidation.
6. **Probe, never infer from a platform name.** FTS5 support, lock backends, symlink
   creation, `chmod` enforcement — all decided by running the thing and looking.

---

## Repository layout

```
config/     self-learning.yaml / .conf   defaults; .conf is what actually ships
            settings-hooks.json          hook template — Claude Code
            copilot-hooks.json           hook template — Copilot CLI
            vscode-hooks.json            hook template — VS Code (Claude Code's schema,
                                           which VS Code parses; not Copilot CLI's)
            claude-md-snippet.md         self-learning protocol for CLAUDE.md
prompts/    curator-review.md            prompt for the curator's opt-in manual
                                           consolidation pass (curator-run.sh
                                           prepares its inventory; a human runs it)
            authoring-standards.md       skill authoring standards
            (the review prompts are NOT here — they are inline in the three
             review scripts, sharing lib/review-common.sh. See that file.)
schema/     session-search-schema.sql    base sessions/messages schema, always applied
            session-search-fts5.sql      FTS5 index + triggers, applied only when
                                           probe_fts5() confirms support
scripts/    hook, review, curator, install/uninstall and doctor scripts (bash + Python)
tests/      suites discovered by glob; `bash tests/run-all.sh` prints the count
vendor/     coach-rules/                 vendored MIT rules + pinned tables
docs/       see below
```

No suite count is recorded here: it drifts on every suite added or removed and has gone
stale in this file repeatedly. Run `bash tests/run-all.sh` and read its
`Discovered N suite(s)` line.

## Documentation

| Document | What it is |
|---|---|
| [`docs/platform-coverage.md`](docs/platform-coverage.md) | What "CI green" does and does not mean, per platform, with the commands to re-derive every figure |
| [`docs/coach-integration.md`](docs/coach-integration.md) | Coach Routes A/B/C in full — the rule partition, the adaptations, the coverage-correction history |
| [`docs/windows-verification-runbook.md`](docs/windows-verification-runbook.md) | Step-by-step protocol for a human to verify this on a real Windows machine. Nothing has ever been installed on one |
| [`docs/superpowers/vscode-adapter-spike.md`](docs/superpowers/vscode-adapter-spike.md) | The VS Code feasibility spike: findings with evidence, the shared-hook-file trap, what is still open |
| [`docs/verification-log.md`](docs/verification-log.md) | Historical manual verification gates (2026-07-23 onward) |
| [`docs/research/`](docs/research/) | The Hermes Agent research corpus — 15 documents, including [`07-implementation-guide-for-claude-code.md`](docs/research/07-implementation-guide-for-claude-code.md), the ~10,000-line implementation guide this project was built from |
| [`docs/project-creation-plan.md`](docs/project-creation-plan.md) | The original plan used to create this project |

The original 5-phase roadmap (foundation → background review → skill lifecycle → curator +
session search → integration and polish) is **complete for all three harnesses**. The VS
Code adapter shipped 2026-07-28 after its spike passed. What is *not* done is recorded
under [Known residuals](#known-residuals) rather than as roadmap items, because none of it
is scheduled work — it is the honest edge of what has been measured.

## License

MIT
