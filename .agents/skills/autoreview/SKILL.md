---
name: autoreview
description: "Use when the human asks for autoreview, a Codex or Claude review, or a second-model review, or before committing a risky or wide-reaching change. Runs a structured code review of local, branch, or commit changes with the bundled helper (Codex by default)."
---

# Auto Review

The bundled helper builds one review bundle, sends it to one review engine in a sanitized read-only workspace, validates the structured JSON result, and exits nonzero when findings are present. Codex is the default engine (`--engine` or `AUTOREVIEW_ENGINE` overrides it); keep whatever engine and model the human asked for.

```bash
.agents/skills/autoreview/scripts/autoreview --help
```

## Pick the Target

| Work | Command |
|------|---------|
| Uncommitted changes in this checkout | `.agents/skills/autoreview/scripts/autoreview --mode local` |
| Branch or PR | `.agents/skills/autoreview/scripts/autoreview --mode branch --base origin/main` |
| A single commit | `.agents/skills/autoreview/scripts/autoreview --mode commit --commit HEAD` |

With no `--mode`, the helper picks dirty local changes first, then the current PR's base (via `gh pr view`), then `origin/main`. After committing, use `branch` or `commit` mode: a `local` review of a clean checkout reviews nothing. For an open PR, use its real base:

```bash
base=$(gh pr view --json baseRefName --jq .baseRefName)
.agents/skills/autoreview/scripts/autoreview --mode branch --base "origin/$base"
```

Useful options: `--prompt`/`--prompt-file` for reviewer context, `--dataset` for extra evidence, `--parallel-tests "<focused test command>"` to run tests alongside the review, `--stream-engine-output` for live progress, `--dry-run` to inspect the bundle. Run `swiftformat .` first so line numbers in findings stay valid.

Multi-reviewer panels (`--panel`, or `--reviewers codex,claude` with optional `--model`/`--thinking` per engine) cost more; use them only when the human asks.

## Handling Findings

Findings are advisory. For each one:

- Check it against the real code path and adjacent files, and against dependency docs or source when it hinges on external behavior.
- Fix what holds up, with the smallest change at the right ownership boundary. If the finding reveals a repeated pattern, fix the sibling instances within the current change too.
- Reject unrealistic edge cases, speculative risks, and fixes that would over-complicate the code. Add an inline comment only when the rejection rests on an invariant future reviewers should know.

If review-driven fixes change code, rerun the focused tests and the review. Stop when the helper exits 0 (`autoreview clean: no accepted/actionable findings reported`), or when every remaining finding has been rejected with a reason. Don't run an extra review just to get a cleaner report.

## Running

- Run the helper yourself so target selection, validation, and exit status stay in one path. Don't hand it to another agent and don't nest reviewers.
- Reviews can take up to 30 minutes. Lines like `review still running: codex elapsed=...s pid=...` mean it is healthy; leave it running while they keep advancing.
- If the engine reports a capacity error, retry the same command with the same engine and model.
- Reviewing doesn't require a push. Push only when the human asked for push, ship, or a PR update.

## Final Report

Include the review command, the tests run, which findings you accepted or rejected and why, and the result of the final helper run.
