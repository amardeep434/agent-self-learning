# Windows verification runbook

**Why this exists.** Every Windows result this project has is from GitHub's
`windows-latest` CI runner. Nothing has ever been installed or exercised on a real
Windows machine by a real user. CI runs the test suite under Git Bash; it does **not**
run `install.ps1`, has no Copilot or VS Code session store, and never fires a hook from a
real harness. Those gaps are the reason for this document.

**Audience:** a Windows work laptop **without Claude Code**. That is fine — the two
harnesses that matter there are **GitHub Copilot CLI** and **VS Code Copilot Chat**, and
every step below is written for them. Steps needing Claude Code are marked `[SKIP — no
Claude Code]` so you can pass over them without wondering whether you broke something.

**How to report back.** Each step says exactly what to copy back. Raw output is better
than a summary — "it worked" is what hid three defects on Linux this week. If a step
fails, send the output and stop; later steps often depend on it.

**Nothing here writes to a real store until Step 4**, and Step 0 takes a backup you can
restore from in one command.

---

## Step 0 — prerequisites and a backup

In **PowerShell**:

```powershell
git --version                     # need Git for Windows (provides Git Bash)
python --version                  # need 3.9+
$PSVersionTable.PSVersion         # need 7+ for the Copilot CLI hooks
where.exe jq                      # jq must resolve; if not, winget install jqlang.jq
copilot --version                 # GitHub Copilot CLI, authenticated
code --version                    # VS Code
```

**Copy back:** all six outputs.

If `jq` does not resolve, stop and install it. A missing `jq` is now *reported* rather
than silently disabling reviews (that was a defect fixed on 2026-07-28), but you want the
system working, not merely honest about being broken.

Backup, in **Git Bash** (not PowerShell):

```bash
BK="$HOME/sl-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
cp -p ~/.copilot/hooks/self-learning.json "$BK/" 2>/dev/null
cp -p ~/.claude/settings.json "$BK/" 2>/dev/null
[ -d ~/.local/share/agent-learning ] && tar czf "$BK/store.tar.gz" -C ~/.local/share agent-learning
echo "$BK"
```

**Copy back:** the printed path.

---

## Step 1 — path resolution (the thing most likely to be wrong)

This project has been bitten repeatedly by MSYS path conversion: `/c/Users/...` versus
`C:/Users/...`. Windows resolves the store under `%LOCALAPPDATA%`, a branch no other
platform takes.

In **Git Bash**, from the cloned repo. The first two lines resolve the interpreter the
same way every installed script does — this runbook used to open with a bare `python3`,
which is the one command name a `winget install Python.Python.3.12` machine does not
have, so it failed at its own first step on exactly the box it targets:

```bash
source scripts/lib/python-resolve.sh && sl_resolve_python && echo "using: $SL_PYTHON"
"$SL_PYTHON" scripts/lib/paths.py all
```

**Copy back:** the whole output. I am checking that `home` lands under `LOCALAPPDATA`,
and which spelling every key uses — they must agree with each other.

---

## Step 2 — the test suite on a real Windows box

```bash
bash tests/run-all.sh 2>&1 | tail -30
```

**Copy back:** the last 30 lines, plus every `SKIP:` line:

```bash
bash tests/run-all.sh 2>&1 | grep -E "^SKIP:|skipped=" | sort -u
```

CI currently skips these on Windows, each gated on a probe rather than a platform name:
symlink creation, `chmod 500` write-denial, pty allocation, and a jq-free PATH. If your
machine skips a *different* set, that is information — Developer Mode, for instance,
enables real symlinks and would un-skip two of them.

---

## Step 3 — the PowerShell installer, dry run

This is the entry point CI has never executed. In **PowerShell**, from the repo root:

```powershell
.\install.ps1 --dry-run
```

`install.ps1` has no parameters of its own — it locates Git Bash and forwards `@args`
straight to `install.sh` (`install.ps1:27`), so `install.sh`'s own flags are what you pass.
That is why it is `--dry-run` and not `-DryRun`.

**Copy back:** the full output, and note whether it found `bash` on its own. `install.ps1`
deliberately refuses to delegate to WSL's `bash.exe`, because that would install into the
WSL filesystem under a different `$HOME`. If it refuses, that refusal is correct
behaviour — send me the message.

---

## Step 4 — the real install

```powershell
.\install.ps1
```

Then, in **Git Bash**:

```bash
source scripts/lib/python-resolve.sh && sl_resolve_python
bash "$("$SL_PYTHON" scripts/lib/paths.py get scripts)/doctor.sh"
```

**Copy back:** the doctor output in full. I am checking the resolved paths, that the
Copilot hook was written and points at the installed scripts dir, and the harnesses-detected
block. `overall: HEALTHY` is the expected result.

`[SKIP — no Claude Code]` The installer prints a JSON block for `~/.claude/settings.json`.
Ignore it — with no Claude Code there is nothing to register. **But note:** VS Code Copilot
Chat reads `~/.claude/settings.json` by default, so if you later want VS Code sessions
reviewed, that block is how you would enable it. Step 6 covers doing it deliberately.

---

## Step 5 — Copilot CLI end to end (the important one)

This is the first real Windows exercise of the loop: a real session, the `sessionEnd` hook,
the detached review, and the writer.

```bash
cd /c/Temp 2>/dev/null || cd "$TEMP"
copilot -s --allow-tool read -p 'Acknowledge two things in one line each: first, that this project uses os.replace rather than Path.rename; second, that tests must never call bare timeout.'
```

Wait ~30 seconds for the detached review, then:

```bash
source <repo>/scripts/lib/python-resolve.sh && sl_resolve_python
S="$("$SL_PYTHON" <repo>/scripts/lib/paths.py all | sed -n 's/^home=//p')"
echo "--- persist.log ---";          tail -5 "$S/logs/persist.log"
echo "--- persist-failures.log ---"; cat "$S/logs/persist-failures.log" 2>/dev/null || echo "(absent)"
echo "--- MEMORY.md ---";            wc -c "$S/memory/MEMORY.md" 2>/dev/null || echo "(none yet)"
```

**Copy back:** all three. What I am looking for:

- a `{"written": [...], "bytes": N}` line in `persist.log` with **N > 0** means the whole
  loop worked on Windows for the first time;
- `{"skipped": ["no-conversation"]}` means the transcript was not found — that is the
  Windows path-form question, and exactly what this step exists to answer;
- anything in `persist-failures.log` now names **which stage** failed and why, so send it
  verbatim.

---

## Step 6 — VS Code Copilot Chat (never tested on Windows at all)

The adapter was spiked on Linux only. Windows is unknown territory: `transcript_path` may
arrive with backslashes, and the transcript lives under `%APPDATA%` rather than
`~/.config`.

First, the **safe probe** — it uses a scratch workspace and cannot touch your real config:

```bash
mkdir -p /c/Temp/vsspike/.github/hooks
cat > /c/Temp/vsspike/.github/hooks/probe.json <<'JSON'
{"hooks":{"Stop":[{"type":"command","command":"/c/Temp/vsspike/probe.sh","timeout":15}],
          "PostToolUse":[{"type":"command","command":"/c/Temp/vsspike/probe.sh","timeout":15}]}}
JSON
cat > /c/Temp/vsspike/probe.sh <<'SH'
#!/usr/bin/env bash
{ printf '=== %s\n' "$(date -Is)"; cat; printf '\n'; } >> /c/Temp/vsspike/probe.log
SH
chmod +x /c/Temp/vsspike/probe.sh
echo "hello" > /c/Temp/vsspike/notes.txt
code /c/Temp/vsspike
```

In that window, open Copilot Chat in **Agent mode** and send **two** prompts in one
session: `Read notes.txt and tell me what it says.` then `What is 2 + 2?`

```bash
cat /c/Temp/vsspike/probe.log
```

**Copy back:** the whole log. I need to see whether hooks fire at all on Windows, whether
the payload arrives on stdin, how many `Stop` events fire, and — critically — the **exact
spelling** of `transcript_path`.

`[SKIP — no Claude Code]` Registering VS Code hooks for real means merging the installer's
JSON into `~/.claude/settings.json` even though Claude Code is absent, since that is the
file VS Code reads. Do **not** do that until the probe above comes back clean.

---

## Step 7 — live telemetry extraction (CI can never test this)

No CI runner has a Copilot store, so the Coach rules' telemetry path is exercised only on
machines like yours.

```bash
source <repo>/scripts/lib/python-resolve.sh && sl_resolve_python
"$SL_PYTHON" <repo>/scripts/coach-rules-eval.py 2>&1 | tail -20
```

**Copy back:** the output, including any `[capability probe]` lines and every skip reason.

---

## What each step closes

| Step | Gap it closes | Currently |
|---|---|---|
| 1 | Windows store resolution under `%LOCALAPPDATA%`, path-form consistency | CI-only |
| 2 | Suite on a real machine; which probes skip on real hardware | CI-only |
| 3-4 | `install.ps1` and a real Windows install | **never run** |
| 5 | Copilot CLI loop end to end on Windows | **never run** |
| 6 | VS Code adapter on Windows | **never run anywhere but Linux** |
| 7 | Live telemetry extraction | **never run in CI on any platform** |

## If something breaks

Restore in one command from **Git Bash**, using the path Step 0 printed:

```bash
BK=<the path from step 0>
cp -p "$BK/self-learning.json" ~/.copilot/hooks/ 2>/dev/null
[ -f "$BK/store.tar.gz" ] && rm -rf ~/.local/share/agent-learning && tar xzf "$BK/store.tar.gz" -C ~/.local/share
```

To remove the system entirely: `bash <repo>/uninstall.sh` (add `--keep-data` to preserve
learned memory and skills).
