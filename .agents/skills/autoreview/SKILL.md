---
name: autoreview
description: "Use after committing non-trivial code changes and before pushing them (Kaset's default), or when the human asks for autoreview, a Codex or Claude review, or a second-model review. Reviews the branch diff with the shared autoreview skill and Kaset's settings."
---

# Auto Review

This repository has no review implementation of its own. Use the shared `autoreview` skill: read the installed `~/.agents/skills/autoreview/SKILL.md` and the references it requires, then follow it together with the Kaset settings below. If it's installed somewhere else, use that installation.

If the skill is missing, install it from [`sozercan/skills`](https://github.com/sozercan/skills/tree/main/skills/autoreview):

```bash
npx skills@latest add sozercan/skills --skill autoreview --global -y
```

Fix shared behavior upstream in that repository, not here.

## Kaset Settings

Review the branch diff from the repository root, against the PR's real base (`main` if there's no PR yet):

```bash
AUTOREVIEW="$HOME/.agents/skills/autoreview/scripts/autoreview"
base=$(gh pr view --json baseRefName --jq .baseRefName 2>/dev/null || echo main)
python3 "$AUTOREVIEW" --mode branch --base "origin/$base" --max-priority P3 --source-context-file AGENTS.md
```

- `--max-priority P3` accepts findings at every priority (P0 through P3); the helper's default of P0 would hide the rest in audit output. Lower priority doesn't mean optional: verify each finding the same way, and reject it only with a reason.
- `--source-context-file AGENTS.md` gives the reviewer the repo rules (credential handling, API-over-WebView, coding rules). It only works in `branch` and `commit` modes; drop it if you're asked to review uncommitted work with `--mode local`.
- When reviewing your own changes, format and commit them first so findings point at stable lines; `branch` mode excludes uncommitted work. For review-only requests, leave the checkout as it is.
- Wait for tests to finish before starting the review; running both at once makes timing-sensitive tests flaky.

Handle findings as described under Code Review in `AGENTS.md`. When you report back, include the review command, the tests you ran, which findings you accepted or rejected and why, and the result of the final run.
