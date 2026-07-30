# Upstream audit, 2026-07-30 — read-back path and reference fidelity

Four Opus 5 subagents audited the harnesses we target and the upstreams we cite, each
briefed to **refute** rather than confirm. Every figure below carries the command that
re-derives it. Where a claim could not be established, it says so — do not upgrade an
"unverified" line here into a fact without running the check.

**Why this exists:** the project was found to write learnings and never deliver them.
Before building a delivery path, we checked what our own upstreams actually do. Two of
this document's findings are defects that exist regardless of what we decide about
delivery.

---

## 1. The consumption gap — CONFIRMED

`scripts/inject-agents-md.py` is installed and has never run. No managed block exists
anywhere.

```bash
grep -c "inject-agents-md" README.md                       # 0 — not even documented
n=$(find ~ -name "AGENTS.md" -o -name "CLAUDE.md" | wc -l)
h=$(find ~ \( -name "AGENTS.md" -o -name "CLAUDE.md" \) \
      -exec grep -l "BEGIN self-learning:managed" {} + 2>/dev/null | wc -l)
echo "$h of $n carry the managed block"                    # measured: 0 of 175
```

Registered hook events are `PostToolUse` and two `Stop` entries — no `SessionStart`:

```bash
python3 - <<'EOF'
import json; d=json.load(open('/home/amardeep/.claude/settings.json'))
for ev,v in d.get('hooks',{}).items():
    for g in v:
        for hk in g.get('hooks',[]):
            if 'agent-learning' in hk.get('command',''): print(ev)
EOF
```

**`README.md:335` claims this feature ships on all three harnesses** — the row
`| AGENTS.md learned-context injection | ✅ | ✅ (also reads CLAUDE.md) | ✅ |` is false in
all three columns. The plan repeats it.

The 2026-07-22 plan's Task 5 specified the file and its test but **named no invoker**, so
this is a gap in the spec, not a regression. Confirm with
`git log --all -S "inject-agents-md.py" -- 'scripts/*.sh' install.sh 'config/*'` — only the
installer-array addition, never a caller.

---

## 2. `[:2200]` silently drops 89% of memory — DEFECT, fix before wiring anything

`scripts/inject-agents-md.py:33` truncates on the **read** side with no ellipsis, no
`persist-failures.log` line, nothing for `doctor.sh` to surface:

```python
return memory_file.read_text(encoding="utf-8", errors="replace")[:MAX_MEMORY_CHARS].strip()
```

```bash
b=$(wc -c < ~/.local/share/agent-learning/memory/MEMORY.md)
python3 -c "b=$b; print(f'{b} bytes; inject 2200 ({2200*100//b}%); drop {b-2200} ({(b-2200)*100//b}%)')"
# measured 2026-07-30: 20752 bytes; inject 2200 (10%); drop 18552 (89%)
```

Hermes uses **the same number the opposite way** — a write-side budget that fails loudly
and forces consolidation (`tools/memory_tool.py:165` `memory_char_limit: int = 2200`;
rejection at `:426-437`). Its read path never truncates. We converted backpressure into
silent amputation. This is hard rule §2's exact failure class, dormant only because the
injector was never wired.

---

## 3. `use_count` is never incremented — DEFECT, unrelated to delivery

```bash
grep -rn "use_count" scripts/ | grep -E "\+= *1|increment"   # no matches
python3 - <<'EOF'
import json, collections
d = json.load(open('/home/amardeep/.local/share/agent-learning/learned-skills/.usage.json'))
print(collections.Counter(v.get('use_count') for v in d.values() if isinstance(v, dict)))
print(collections.Counter(v.get('view_count') for v in d.values() if isinstance(v, dict)))
EOF
# measured 2026-07-30: use_count Counter({0: 50}) ; view_count Counter({None: 50})
```

`prompts/curator-review.md:51` gates archival on `AND use_count > 0` — **unreachable**.
`:55` says "any `view_count` increment reactivates" — that field is never written at all.
So the curator archives on wall-clock staleness only, and both upstreams that gate skills
do it on **outcomes** (SkillOpt `skillopt_sleep/gate.py:37-50`, accept only
`cand_score > current_score`; GEPA ships a with/without A/B harness).

---

## 4. MIT notice clause is not satisfied — legal, trivially fixable

45 verbatim rule files plus two verbatim TypeScript slices are substantial portions.

```bash
grep -rln "Permission is hereby granted, free of charge" . --exclude-dir=.git
# only ./LICENSE, whose holder is "Copyright (c) 2026 Amardeep Singh Arora"
grep -rn "Copyright (c) Microsoft" . --exclude-dir=.git    # zero hits
```

Our whole attribution is one line, `vendor/coach-rules/UPSTREAM.md:1`. The extraction also
dropped upstream's file header (`Copyright (c) Microsoft Corporation. All rights
reserved.`) from both vendored `tables/*.ts` slices. The asymmetry is self-evident:
`vendor/coach-rules/tables/profanity-sha256.txt:3` correctly carries
`MIT License, Copyright (c) 2017 Nathachai Thongniran.` — we know how, and did it for
leo-profanity but not for Microsoft.

"The rules are MIT" is true. "Our attribution satisfies MIT" is not supported.

---

## 5. Route B ignores the version upstream stamped for us

```bash
grep -n "schemaVersion" scripts/coach-export-read.py   # zero hits outside the docstring
```

Upstream declares `schemaVersion: 1` (`src/core/summary-export.ts:39`) as an explicit
exported contract precisely so consumers can refuse an incompatible payload. We reach
straight for `report["antiPatterns"]["topPatterns"]`. A `schemaVersion: 2` that
re-semanticises `occurrences` would be consumed silently with the wrong denominator —
a plausible wrong prevalence, i.e. the silent-wrong-value class this project exists to
eliminate.

Also re-frame one number: **10 is upstream's hard cap**, not a reduction we performed
(`summary-export.ts:82` `TOP_ANTI_PATTERN_LIMIT = 10`, applied `:146`). Route B can never
surface an 11th anti-pattern however prevalent. "32,929 occurrences → 10 signals" invites
the wrong reading.

---

## 6. Vendoring is current — no drift

```bash
ls -1 vendor/coach-rules/*.md | grep -v UPSTREAM | wc -l          # 45
grep "Commit:" vendor/coach-rules/UPSTREAM.md
gh api repos/microsoft/AI-Engineering-Coach/commits/main --jq .sha
# measured 2026-07-30: both 766d0f2966f7fe3816da81b91d566d614c615f57 — pin IS upstream HEAD
```

All 45 files byte-identical to upstream; both table SHA-256 pins re-derive.

> **Trap when re-deriving the table pins.** Hashing `extract_tables()` raw output does
> *not* match `TABLE_PINS` — it differs by a single trailing newline. `coachtables.py`'s
> `_main` normalises (`body = slice_text if slice_text.endswith("\n") else slice_text + "\n"`)
> before hashing. Re-derive without that and you will wrongly conclude drift.

Pinning covers only the 3 table artefacts; the 45 rule `.md` files have no hash pin, so a
hand-edit to a rule's `# How to Improve` prose — the text that reaches the user's memory
file — is detected by nothing.

---

## 7. `no-devcontainer` — CONFIRMED, but the reason text overstates it

The quoted upstream code is real. `src/core/dsl/interpreter.ts:579` gates on
`VSCODE_HARNESSES = new Set(['VS Code', 'VS Code Insiders', 'Local Agent', 'Local Agent (Insiders)'])`,
and neither `'Claude'` (`parser-claude.ts:75-77`) nor `'GitHub Copilot CLI'`
(`parser-vscode-cli.ts:29-31`) is a member.

**But plain VS Code is labelled `'Local Agent'`, which IS in that set**
(`parser-vscode.ts:18-26`). We ship VS Code Copilot Chat as a declared peer harness. The
rule is unreachable because **our telemetry has no VS Code source**, not because no
supported harness can satisfy the gate:

```bash
grep -n '"harness"' scripts/lib/telemetry.py scripts/coach-rules-eval.py   # zero hits
grep -n "_vscode_" scripts/lib/telemetry.py                                # no reader
ls ~/.config/Code/User/workspaceStorage/*/chatSessions 2>/dev/null | head  # data is present
```

This is the same shape as the correction already recorded at
`docs/coach-integration.md:91-94` — *"The telemetry was unplumbed here, not
unobtainable."* The reason text should read "unreachable **while no VS Code session source
is plumbed into telemetry.py**" — checkable, falsifiable, and pointing toward work rather
than away from it.

---

## 8. What the upstreams actually do about delivery

| upstream | delivery mechanism | selective? |
|---|---|---|
| Hermes Agent | memory + skill index injected into the **system prompt**, volatile tier | **no — wholesale, by design** |
| SkillOpt-Sleep | writes one `SKILL.md` into `~/.claude/skills/skillopt-sleep-learned/` | no — one gated document |
| GEPA / gskill | `best_skills.txt` into the system prompt, or `.claude/skills/<repo>/SKILL.md` | no |
| AI-Engineering-Coach | 12 VS Code language-model tools + `@aicoach` participant; writes `~/.agents/skills/<slug>/SKILL.md` on an explicit human click | pull-based |

**Wholesale injection is correct, and a relevance filter would be wrong.** Hermes forbids
pruning the index explicitly (`agent/prompt_builder.py:1789-1793`): *"NEVER remove entries
entirely: agent-created skills are the model's project memory, and models don't reach for
skills_list to rediscover what the index stops showing them."* It does this at 70+ skills;
our 46 is not a scale upstream treats as a problem.

The apparent conflict with SkillOpt/GEPA — which ship exactly **one** document and warn
*"Adding skills blindly will not help the agent"* — resolves by layer: Hermes is the
runtime architecture (index in prompt, bodies on demand); SkillOpt/GEPA are optimisers
that compress many lessons into one artefact under an outcome gate. We copy Hermes'
runtime and have **neither's outcome gate** (see §3).

**All four agree on one thing we do not do: deliver by writing where the harness already
looks.** Ours goes to `<store>/learned-skills/`, which no harness discovers
(`scripts/lib/paths.py:28` → `"skills": ("learned-skills",)`). That reframes the root
cause as a **location** problem, not a missing hook — and it means mirroring into
`~/.claude/skills/` deserves reconsideration; it was previously dismissed on
harness-neutrality grounds that no upstream shares.

Also: skipping SkillOpt's MCP server costs nothing. MCP is a Copilot-specific invocation
transport wrapping the same CLI verbs (`plugins/copilot/mcp_server.py:88,118`), not the
delivery mechanism.

---

## 9. Highest-severity omission: no threat gate on the read path

Hermes scans every memory entry at snapshot-build time and substitutes `[BLOCKED: …]` in
the **injected** text while leaving the raw entry on disk for the user to inspect. We are
about to start injecting, into every future session, a file written by an LLM that reads
arbitrary session transcripts. That is a prompt-injection channel into all future
sessions.

Coach goes further and ships the stronger mechanism for exactly our input class —
**spotlighting via datamarking** (`src/core/spotlight.ts:6-21`, Microsoft 2024,
*"Defending Against Indirect Prompt Injection Attacks With Spotlighting"*), whose guidance
names transcript snippets as the first thing to datamark and reserves plain delimiting for
content whose formatting must be preserved. We use delimiting
(`scripts/lib/review-common.sh:132`) — upstream's option for the *other* case.

Upstream also records an ordering constraint we would need: redaction must run **before**
datamarking, because some redaction patterns depend on whitespace
(`spotlight.ts:29-33`). We have the redaction half (`scripts/lib/transcript.py:267
redact_secrets`, applied `:571,:700,:841`); the datamarking layer is absent.

---

## 10. Harness contract for a `SessionStart` hook — all MEASURED

| | Claude Code 2.1.220 | VS Code 1.130.0 | Copilot CLI 1.0.75 |
|---|---|---|---|
| accepted shape | nested only | nested only | **flat** only |
| wrong shape | rejected **+ warning** | silently dropped | silently dropped |
| fires on | `startup, resume, clear, compact, fork` | first turn of a chat thread | once per session |
| failure mode | — | silent (`ignoreErrors`) | silent |

- Nested: `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`
- Flat: `{"additionalContext":"…"}`

```bash
# Claude Code ships a warning written for exactly the both-keys-in-one-object trick:
grep -ao "Did you mean hookSpecificOutput.additionalContext[^\"]*" \
  ~/.local/share/claude/versions/2.1.220 | head -1
# VS Code's per-thread gate (NOT per turn, unlike Stop):
grep -ao "turns.length===1.\{0,80\}" \
  /usr/share/code/resources/app/extensions/copilot/dist/extension.js | head -1
# ~/.claude/settings.json is a shipped VS Code default hook location:
grep -ao 'Mit=\[{path:"\.github/hooks".\{0,300\}' \
  /usr/share/code/resources/app/out/vs/workbench/workbench.desktop.main.js
# Copilot's flat-only output type:
grep -A3 "interface SessionStartHookOutput" \
  /usr/share/code/resources/app/node_modules.asar.unpacked/@github/copilot-linux-x64/sdk/index.d.ts
```

**Emitting both keys in one object was measured to work but is wrong**: Claude Code logs
`Hook JSON output had unrecognized keys (ignored)` on every session start, and Copilot's
native struct already honours `hookSpecificOutput` for `preToolUse` compat, so extending
that to `sessionStart` would turn the trick into a genuine double injection. Use a
two-way split. Claude Code and VS Code need no distinction from each other — identical
payload — so the `--harness auto` sniffing is not needed here. The discriminator is
structural: Copilot sends camelCase `sessionId`/`timestamp`; Claude Code and VS Code send
snake_case `session_id`/`transcript_path`.

**Copilot concatenates all non-progress stdout and runs one `JSON.parse`.** One stray
`echo` silently kills the injection. Diagnostics must go to `persist-failures.log`, never
stdout.

### Version trap that invalidated an earlier conclusion

The VS Code bundle ships Copilot CLI **1.0.70-0**; the binary on PATH is **1.0.75**, and
between them the entire hook engine moved from JS into the Rust runtime. Reading the
bundled copy and generalising to the installed CLI is wrong.

```bash
copilot --version
python3 -c "import json;print(json.load(open('/usr/share/code/resources/app/node_modules.asar.unpacked/@github/copilot-linux-x64/package.json'))['version'])"
ls ~/.cache/copilot/pkg/linux-x64/     # the PATH binary self-extracts here — readable
```

`copilot` self-updates, so re-derive after any update.

---

## WHAT WAS NOT VERIFIED

- **No hook has ever fired.** Every harness verdict except Copilot's is read off shipped
  code and disassembly. The Copilot result alone is a true runtime measurement — an agent
  loaded `runtime.node` and invoked the real parser directly (no `copilot` process, no
  session, no credits). **The acceptance bar for any delivery work must therefore be a
  real fired hook, not a green unit test.**
- VS Code's adapter has still never been invoked by real VS Code on any machine.
- **Whether Coach's 12 `languageModelTools` are reachable from general VS Code agent mode**
  or only from `@aicoach`. None declares `canBeReferencedInPrompt`. If they *are* reachable,
  upstream has a working agent-facing pull surface and our framing of the delivery problem
  changes. Most decision-relevant unknown in this document.
- **Whether Hermes' builtin memory provider has a per-turn `prefetch(query)` retrieval
  path.** The Hermes auditor flagged this as its own likeliest error. Also unexamined:
  `plugins/memory/`'s 10 RAG backends — so "no retrieval upstream" holds only for the
  default path; retrieval is an additive provider there, never a filter.
- Whether a plumbed VS Code telemetry source would actually make `no-devcontainer` fire
  (needs `toolConfirmations[].isTerminal` in VS Code's `chatSessions` JSON — not opened,
  live user data).
- Hermes corpus line numbers are stale against upstream `main` (e.g. `memory_tool.py:130`
  → `165`). Content held up; citations do not.
- Non-Linux everything. No Windows or macOS verification of any finding here.
