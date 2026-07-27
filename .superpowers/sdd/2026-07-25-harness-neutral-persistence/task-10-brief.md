### Task 10: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none.

**Context:** `CLAUDE.md` currently describes Phase 1 as "Skeleton" and Phases 2-5 as "Planned" against 34 merged commits. Docs drift is a stated gate; this task closes the drift introduced before and by this plan.

- [ ] **Step 1: Update `README.md`**

Add a "Storage locations" section stating the resolution order (`AGENT_LEARNING_HOME` → `XDG_DATA_HOME/agent-learning` → `%LOCALAPPDATA%\agent-learning` → `~/.local/share/agent-learning`), a "Migrating from ~/.claude" note pointing at `scripts/doctor.sh`, and a note that `CLAUDE_REVIEW_ENABLED` is deprecated in favour of `SL_REVIEW_ENABLED`. Update the compatibility table so no row claims a harness is supported unless `tests/run-all.sh` covers it.

- [ ] **Step 2: Update `CLAUDE.md`**

Correct the roadmap table to reflect merged state, and add one line stating that Claude Code is one adapter among peers and that no shared code path may depend on it.

- [ ] **Step 3: Verify the claims**

Run: `bash tests/run-all.sh && bash scripts/doctor.sh`
Expected: all tests pass; doctor output matches the paths documented in the README.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: storage locations, migration, deprecation, corrected roadmap"
```

---

## Verification Gate (run before opening the PR)

- [ ] `bash tests/run-all.sh` passes locally
- [ ] `bash tests/test-claude-absent.sh` passes — the harness-independence guard
- [ ] All six CI matrix jobs green (3 OS × 2 Python)
- [ ] `bash scripts/doctor.sh` on a machine with an existing `~/.claude` store reports the legacy path and does not move anything
- [ ] `grep -rn 'claude' scripts/copilot-session-review.sh scripts/persist-proposal.py scripts/lib/paths.py` returns no binary invocation and no `~/.claude` path default
- [ ] Manual live check on Copilot CLI: run a real session, confirm a file appears under the resolved memory directory with real content — the specific failure this plan exists to fix

## Out of Scope (subsequent plans)

Session-source adapters (Copilot `session-store.db`, Claude JSONL) · VS Code hook spike and adapter · Copilot `postToolUse` turn counting · measurement (usage reader, continuous holdout, reporting norms) · failure-triggered review · install UX, install manifest, manifest-driven uninstall · deep security audit · all `graphify-offline` work (XML, BeanShell, PDF extraction).
