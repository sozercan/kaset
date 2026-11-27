---
name: delete-comment
description: Audit or remove Kaset source comments, classify them as tautology, excuse, stale, or decision record, and verify the comment ratchet. Do not use for end-user YouTube comments or general documentation editing.
---

# Delete Comment

From the repository root, use `python3 Scripts/comment_lint.py --inventory` to count comments and `python3 Scripts/comment_lint.py --list` to locate them. Add `--revision <ref>` to inventory committed state. Use the SwiftFormat version pinned in `.github/workflows/lint.yml`. Read [ADR-0042](../../../docs/adr/0042-ratchet-source-comments.md) for gate coverage and exceptions; inspect comments in embedded code manually if it is in scope.

Read each comment with its code and relevant tests, docs, or Git history. Treat consecutive lines that convey one thought as one comment for review, even though the linter counts each line-comment token separately. Classify and act:

| Category | Evidence | Action |
| --- | --- | --- |
| Tautology | Repeats what the code already makes evident. | Delete it. |
| Excuse | Rationalizes actual implementation debt with a plausible better approach. | Search for an existing issue, then delete the comment and link that issue or file a new one when authorized. Include affected code and a testable outcome. Don't fix the implementation in the cleanup. |
| Stale | Describes behavior, a constraint, or a next step that no longer applies. | Verify against current code or history, then delete it. |
| Decision Record | Explains a non-obvious invariant, tradeoff, or external constraint that's still relevant. | Update a relevant ADR or create one in `docs/adr/`, then remove the inline version. |

Preserve required headers, generated metadata, vendored code, active lint or formatter directives, and exact `# vX.Y.Z` release annotations on SHA-pinned GitHub Actions `uses:` entries. Verify the annotation against the tag without changing the pin. Remove a directive only after verifying its target no longer needs it. The ratchet still rejects new directives, so the inventory can be nonzero even when no prose remains. For an exhaustive audit, check embedded JavaScript, CSS, shell, and heredoc source separately; preserve comment-like string content such as help text and parser fixtures. For a large audit, work in reviewable batches and distinguish the locations inventoried from those actually classified. If issue filing isn't authorized or cannot be completed, report the candidate and leave the comment until the follow-up is recorded.

Run `python3 Scripts/comment_lint.py --base <merge-base>` and relevant checks. For a `main`-bound branch, find the merge base with `git merge-base HEAD origin/main`. Use `--list` to confirm what remains. Report before/after comment-only lines, any manually counted embedded removals, documents and issues created or reused, and retained exceptions. Mixed code/comment lines and new ADR text are not source-line savings.
