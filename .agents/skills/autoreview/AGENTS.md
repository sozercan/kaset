# Autoreview Skill

- Canonical source: `openclaw/agent-skills`, under `skills/autoreview`.
- Before editing any copy, fast-forward a checkout of `openclaw/agent-skills` from `origin/main`.
- Sync and validate the complete canonical directory, then omit the upstream tests, fixtures, optional `scripts/test-review-harness*` wrappers, and `references/repository-entrypoint.md`. Reapply the three downstream overrides documented in `README.md` and retain only their focused downstream test.
- Do not add other repo-local behavior variants without explicit authorization.
