# ADR-0009: Prompt Request Workflow

## Status

Accepted

## Context

AI coding assistants (GitHub Copilot, Claude, Cursor, etc.) are increasingly capable of generating high-quality code from natural language prompts. Traditional pull requests focus on reviewing the resulting code diff, but this approach has limitations in the AI-assisted development era:

1. **Code diffs hide intent** — A large code change doesn't clearly communicate *why* the change was made or what problem it solves.
2. **Review friction** — Reviewers must reverse-engineer the contributor's goals from the code.
3. **Reproducibility** — Others cannot easily regenerate or iterate on AI-generated code without knowing the original prompt.
4. **Barrier to contribution** — Contributors comfortable with prompts but not Swift development may have valuable ideas they can't easily contribute.

The concept of "prompt requests" (attributed to Peter Steinberger / @steipete) proposes sharing the AI prompt that generates code changes, allowing review of intent before or alongside implementation.

## Decision

We adopt a **prompt request workflow** that allows contributions in three forms:

### 1. Traditional PRs (with optional prompt disclosure)

Standard code contributions where contributors may optionally share the AI prompt used to generate the code in the PR template.

### 2. PRs with Prompt Disclosure (Encouraged)

For AI-generated code, we encourage (but don't require) sharing the prompt that produced the changes. This helps reviewers:
- Understand the contributor's intent
- Validate the prompt logic before reviewing implementation details
- Suggest improvements to the prompt rather than line-by-line code fixes

### 3. Prompt-Only Contributions (Prompt Requests)

Contributors can submit a prompt via the "Prompt Request" issue template without generating code. Maintainers can:
- Review the prompt for feasibility and alignment with project goals
- Iterate on the prompt with the contributor
- Run the approved prompt to generate and merge the code

### Implementation

- **Issue Template**: New `prompt_request.yml` template for prompt-only contributions
- **PR Template**: Added "AI Prompt" section for disclosing prompts used
- **CONTRIBUTING.md**: New section documenting the workflow
- **AGENTS.md**: Guidance for AI agents to document prompts for PR inclusion

## Consequences

### Positive

- **Faster contribution review** — Intent is clear from the prompt, reducing back-and-forth
- **Lower barrier to entry** — Contributors can propose changes without writing Swift
- **Better reproducibility** — Prompts can be re-run to verify or update changes
- **Knowledge sharing** — Effective prompts become reusable patterns
- **AI agent compatibility** — AI assistants can be instructed to document their prompts

### Negative

- **Additional overhead** — Contributors must document prompts (though this is optional for manual code)
- **Prompt variation** — Same prompt may produce different results across AI tools or versions
- **Security consideration** — Prompts must be reviewed to ensure they don't inadvertently request credential exposure

### Neutral

- **Not a replacement** — Prompt requests supplement, not replace, traditional code review
- **Tool-agnostic** — The workflow doesn't mandate specific AI tools
