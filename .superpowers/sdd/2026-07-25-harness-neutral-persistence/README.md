# SDD workspace — harness-neutral-persistence

The execution record for this branch: what was asked of each subagent, what it
reported back, what each review found, and every ruling the controller made.

`git log` is the source of truth for what the code *is*. This directory is the
source of truth for **why** — which is the part that is otherwise unrecoverable.

## What is here

| File | Contents |
|---|---|
| `progress.md` | **The ledger.** One append-only record of every task completion, ruling, deferred minor, and review verdict, in execution order. Read this first. |
| `task-N-brief.md` | The requirements handed to each implementer, generated from the plan. |
| `task-N-report.md` | What that implementer did, every deviation with reasoning, and its mutation-test results. |
| `fix-round-{A..E}-report.md` | The six post-review fix rounds. Round F is appended inside the round-E report. |
| `review-<base>..<head>.diff` | **Untracked, derived.** See below. |

Task numbering has gaps and additions: 7b and 7c were added during execution
when reviews found that install locations and three scripts still resolved a
hardcoded `~/.claude`. There is no separate task-7b/7c entry in the original
plan file's task list — they were appended to the plan mid-flight, commits
`44209dc` and `612816e`.

## Regenerating the review diffs

The `.diff` files are byte-identical to `git diff <base>..<head>` for the SHAs
in each filename (verified 2026-07-25). They are gitignored to avoid ~800K of
duplication. To rebuild one:

```bash
git diff <base>..<head>
```

Or rebuild a full review package with the SDD helper:

```bash
bash <superpowers>/skills/subagent-driven-development/scripts/review-package \
     docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md <base> <head>
```

## Reading order for someone picking this up cold

1. `progress.md` top to bottom — it is chronological and self-contained.
2. The whole-branch final review verdict inside it (search `WHOLE-BRANCH FINAL
   REVIEW`), which is where the four Critical findings and the deferred-minor
   triage live.
3. `fix-round-A..E` reports for how those findings were closed, and which CI
   run proved each one.

## A caution the record itself earned

Several documents in this tree were, at the time of writing, accurate and later
became false — most notably the original handoff's task counts and CI claims.
Two separate agents caught and refused to propagate stale figures from their own
briefs. Treat any number written here (commit counts, suite counts, "N tasks
complete") as true only as of its surrounding text, and verify against `git log`
and `bash tests/run-all.sh` before relying on it.
