# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the Kaset project.

## What is an ADR?

An ADR is a document that captures an important architectural decision made along with its context and consequences. ADRs help:

- **Preserve context** for why decisions were made
- **Onboard new team members** faster
- **Avoid repeating discussions** about past decisions
- **Document trade-offs** considered during design

## Format

Each ADR follows this format:

```markdown
# ADR-NNNN: Title

## Status
[Proposed | Accepted | Deprecated | Superseded by ADR-XXXX]

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult because of this change?
```

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-webview-playback.md) | WebView-Based Playback | Accepted |
| [0002](0002-protocol-based-services.md) | Protocol-Based Service Design | Accepted |
| [0003](0003-modular-api-parsers.md) | Modular API Response Parsers | Accepted |
| [0004](0004-streaming-foundation-models.md) | Streaming Responses for Foundation Models | Accepted |
| [0005](0005-foundation-models-architecture.md) | Foundation Models Architecture | Accepted |
| [0006](0006-swift-testing-migration.md) | Swift Testing Migration | Accepted |
| [0007](0007-sparkle-auto-updates.md) | Sparkle Auto-Updates | Accepted |
| [0008](0008-nonisolated-network-helpers.md) | Nonisolated Network Helpers for MainActor Classes | Accepted |
| [0009](0009-prompt-request-workflow.md) | Prompt Request Workflow | Accepted |
