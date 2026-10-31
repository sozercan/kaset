---
name: autoreview
description: "Use when the human asks for autoreview, a Codex or Claude review, or a second-model review, or before committing a risky or wide-reaching change. Runs the shared autoreview skill with Kaset's review settings."
---

# Auto Review

This repository has no review implementation of its own. Use the shared `autoreview` skill: read the installed `~/.agents/skills/autoreview/SKILL.md` and the references it requires, then follow it together with the Kaset settings below. If it's installed somewhere else, use that installation.

If the skill is missing, install it from [`sozercan/skills`](https://github.com/sozercan/skills/tree/main/skills/autoreview):

```bash
npx skills@latest add sozercan/skills --skill autoreview --global -y
```

Fix shared behavior upstream in that repository, not here.

## Kaset Settings

Run the helper from the repository root:

```bash
AUTOREVIEW="$HOME/.agents/skills/autoreview/scripts/autoreview"
python3 "$AUTOREVIEW" --mode branch --base origin/main --max-priority P1 --source-context-file AGENTS.md
```

- `--max-priority P1` accepts P0 and P1 findings. P2 and P3 stay in the audit output; fix them only when they're cheap and clearly correct.
- `--source-context-file AGENTS.md` gives the reviewer the repo rules (credential handling, API-over-WebView, coding rules). It only works in `branch` and `commit` modes. For uncommitted work use `--mode local`, and for an open PR use its real base (`gh pr view --json baseRefName --jq .baseRefName`).
- Run `swiftformat .` before reviewing so line numbers in findings stay valid.

Findings are advisory. Check each one against the real code path, fix the ones that hold up, and rerun the focused tests and the review once after review-driven code changes. When you report back, include the review command, the tests you ran, which findings you accepted or rejected and why, and the result of the final run.
