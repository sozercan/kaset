# 0016. Staged Command Parsing And Queue Analysis

Date: 2026-04-15

## Status

Accepted

## Context

Kaset's command bar had already moved to a local-first architecture, but the AI path still used a broad `MusicIntent` schema as its first contract. That left two issues:

- ambiguous phrases still had to fit a playback-oriented schema, which made read-only intents like queue inspection harder to represent safely
- queue analysis used plain text responses without structured streaming, so the command bar could not show progressive analysis and had no schema-level guarantees about the response shape

The product behavior also drifted from the architecture:

- the `⌘K` entry point was still hidden when Apple Intelligence was unavailable, even though the command bar now had deterministic non-AI behavior
- the settings UI exposed a "Clear AI Context" control even though Kaset creates fresh Foundation Models sessions per request and had no persistent session context to clear

## Decision

Kaset now uses a two-stage command-bar AI contract:

- `CommandBarParseResult` is the stage-1 parse schema for command-bar AI requests.
- Stage 1 is intentionally command-bar-specific and includes explicit read-only and destructive actions like `inspectQueue` and `clearQueue`.
- `MusicIntent` remains the execution-oriented payload for music search and playback heuristics after stage-1 parsing decides that a content request should be executed.

Queue analysis now uses a structured `QueueAnalysisSummary` response:

- queue analysis streams partial structured output into the command bar
- queue prompts are fit to the available token budget before execution
- queue analysis focuses on a window around the current song instead of a naive first-N slice

The surrounding UX is aligned with that architecture:

- the toolbar `⌘K` command bar entry point stays available even when Apple Intelligence is off
- Intelligence settings no longer imply there is persistent AI context to clear; they offer availability refresh instead

## Consequences

Positive:

- ambiguous queue-reading requests can be routed to an explicit read-only action instead of being coerced into playback or queue-mutation schemas
- queue analysis is more trustworthy and more legible because it is structured, streamed, and token-budget-aware
- the command bar remains useful as a command surface even without Apple Intelligence
- the settings UI is more honest about Kaset's stateless session model

Tradeoffs:

- the AI contract is now split across a stage-1 parse model and an execution model, which adds another type to maintain
- queue analysis introduces a second structured AI response model and more test surface
