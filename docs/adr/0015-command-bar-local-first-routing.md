# 0015. Command Bar Local-First Routing

Date: 2026-04-15

## Status

Accepted

## Context

Kaset's command bar previously concentrated request lifecycle management, Apple Intelligence orchestration, fallback logic, and playback execution inside `CommandBarView`. That made the feature harder to test and left it exposed to overlapping requests, long-running model calls, and AI-dependent latency for commands that were deterministic enough to execute locally.

The command bar also routed search fallback through the debounced `SearchViewModel.search()` path, which added avoidable delay when the user explicitly asked to search or when AI parsing failed.

## Decision

Kaset now uses a local-first command bar architecture:

- `CommandBarViewModel` owns single-flight request orchestration, cancellation, timeout handling, fallback reason tracking, and Apple Intelligence gating.
- `CommandIntentParser` short-circuits deterministic playback and queue commands before any Foundation Models work.
- `CommandExecutor` owns execution of local commands, search playback, queue mutations, and AI-produced `MusicIntent` results.
- `ContentSourceResolver` owns search query building, result descriptions, and curated-source routing instead of keeping that logic embedded in `MusicIntent`.
- The Apple Intelligence command path uses a fresh tool-free `LanguageModelSession` for command parsing, with locale checks and prompt-prefix prewarming when the command bar opens.
- Search routing uses `SearchViewModel.searchImmediately()` to avoid debounce when command-bar flows intentionally open the Search tab.

## Consequences

Positive:

- Deterministic commands like pause, resume, skip, previous, like, dislike, clear queue, and shuffle queue complete without model latency.
- The command bar enforces single-flight behavior and cancels in-flight work when it is dismissed.
- Decode failures, busy-session errors, timeouts, and unavailable AI now fall back to deterministic behavior instead of leaving the UI spinning.
- Command parsing and execution are testable without rendering the SwiftUI view.

Tradeoffs:

- Command routing logic is now split across more focused types, which increases file count.
- The initial AI command stage is intentionally narrower and tool-free; future grounded follow-up stages will need explicit expansion if queue-aware or catalog-grounded AI actions grow.
