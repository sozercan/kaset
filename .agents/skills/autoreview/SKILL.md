---
name: autoreview
description: "Run a structured code review (Codex default, Claude optional) as a closeout check on a local or PR branch before commit or ship."
---

# Auto Review

Run the bundled structured review helper as a closeout check. This is code review, not
Guardian `auto_review` approval routing.

Codex review is the default when no engine is set. It usually delivers the best review
results and should remain the normal final closeout engine.

Use when:

- user asks for Codex review / Claude review / autoreview / second-model review
- after non-trivial code edits, before final/commit/ship
- reviewing a local branch or PR branch after fixes

Flags, panels, non-macOS invocation, and operational edge cases live in
[`reference.md`](reference.md) — read it when you need one, not upfront.

## Contract

**Verifying findings**

- Treat review output as advisory. Never blindly apply it. Verify every finding by
  reading the real code path and adjacent files, plus dependency docs/source/types when
  the finding depends on external behavior.
- Reject unrealistic edge cases, speculative risks, broad rewrites, and fixes that
  over-complicate the codebase.
- Security perspective is always included, but it should not cripple legitimate
  functionality. Report security findings only when the change creates a concrete,
  actionable risk or removes an important safety check.
- If rejecting a finding as intentional, add a brief inline code comment only when it
  explains a real invariant or ownership decision that future reviewers should know.

**Scoping fixes**

- Prefer small fixes at the right ownership boundary; no refactor unless it clearly
  improves the bug class.
- When an accepted finding shows a bug class or repeated pattern, inspect the current PR
  scope for sibling instances and fix them together when practical. Stop at touched
  surfaces, owner boundaries, and clear follow-up territory.

**Running the helper**

- Keep going until structured review returns no accepted/actionable findings. If a
  review-triggered fix changes code, rerun focused tests and rerun the helper.
- Stop as soon as the helper exits 0 with no accepted/actionable findings. That is the
  clean result even if the underlying CLI output is terse — do not run another review for
  a second opinion or nicer closeout wording.
- Never switch or override the requested review engine/model. If the review hits model
  capacity, retry the same command with the same engine/model.
- Reviews are slow. A large bundle can take up to 30 minutes with the model call active,
  and `review still running: ... elapsed=... pid=...` heartbeats are healthy progress, not
  a hang. Inspect the process only after missing multiple expected heartbeats, after 30
  minutes, or after an obviously failed subprocess.
- Do not invoke built-in `codex review`, nested reviewers, or reviewer panels from inside
  the review. The helper builds one bundle, calls one engine, validates one structured
  result, and stops.
- Do not push just to review. Push only when the user requested push/ship/PR update.

## Pick Target

Dirty local work:

```bash
<autoreview-helper> --mode local
```

Use this only when the patch is actually unstaged/staged/untracked in the current
checkout. For committed, pushed, or PR work, point the helper at the commit or branch
diff instead; do not force dirty modes just because the helper docs mention dirty work
first. A clean local review only proves there is no local patch.

Branch/PR work:

```bash
<autoreview-helper> --mode branch --base origin/main
```

If an open PR exists, use its actual base:

```bash
base=$(gh pr view --json baseRefName --jq .baseRefName)
<autoreview-helper> --mode branch --base "origin/$base"
```

Committed single change:

```bash
.agents/skills/autoreview/scripts/autoreview --mode commit --commit HEAD
```

Use commit review for already-landed or already-pushed work on `main`. Reviewing clean
`main` against `origin/main` is usually an empty diff after push. For a small stack,
review each commit explicitly or review the branch before merging with `--base`.

## Parallel Closeout

Format first if formatting can change line locations. Then it is OK to run tests and
review in parallel:

```bash
.agents/skills/autoreview/scripts/autoreview --parallel-tests "<focused test command>"
```

Tradeoff: tests may force code changes that stale the review. If tests or review lead to
code edits, rerun the affected tests and rerun review until no accepted/actionable
findings remain.

## Context Efficiency

Run the helper directly so target selection, engine choice, structured validation, and
exit status all stay in one path. If output is noisy, summarize the completed helper
output after it returns; do not ask another agent or reviewer to rerun the review.

## Final Report

Include:

- review command used
- tests/proof run
- findings accepted/rejected, briefly why
- the clean review result from the final helper run, or why a remaining finding was
  consciously rejected
