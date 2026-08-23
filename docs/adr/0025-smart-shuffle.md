# 25. Smart Shuffle (tri-state shuffle with interleaved recommendations)

Date: 2026-06-28

## Status

Accepted

## Context

Shuffle was a binary `Bool` on `PlayerService`. We want a Spotify-style "Smart Shuffle"
that shuffles the queue and interleaves recommended tracks not already in the playlist,
topping up forever.

## Decision

- Model shuffle as `enum ShuffleMode { off, on, smart }` with a computed
  `shuffleEnabled: Bool { mode != .off }` shim so every existing reader (WebQueueSync, UI,
  scripting, `PlayerServiceProtocol`) is unchanged.
- Seed recommendations via the existing `getRadioQueue(videoId:)`. Suggestions are placed by
  a rolling window: each insertion slot is seeded from the original track immediately
  preceding it, so picks stay locally coherent across a multi-genre playlist. Because radio
  has no continuation token, the window tops up by re-seeding from later originals rather
  than paginating, and deduplicates candidates by `videoId` against the live queue.
- Entering smart is two-phase: instant plain shuffle, then an async window fill. Leaving
  smart strips not-yet-played suggestions and restores the playlist.
- Mark suggested entries with `QueueEntry.source = .suggested`. Suggestions are *ephemeral*:
  they are stripped before persistence (keeping only the currently-playing track) and
  regenerated from live playback context after restore — never persisted or re-tagged. A
  stale persisted snapshot would otherwise fight the rolling window.
- `⌘S` / menu / mini-player / AppleScript / AI keep the binary on/off toggle; only the
  player-bar control cycles to smart.

## Consequences

- New `PlayerService+SmartShuffle.swift` holds pure helpers (`nextSuggestionSlot`,
  `dedupeSuggestions`, `stripSuggested`) plus async orchestration (`fillSmartShuffleWindow`);
  helpers are unit-tested without network.
- Interleave cadence, per-insertion burst, and how many suggestions to keep queued ahead are
  user-configurable (`SettingsManager.smartShuffle*`), and Smart Shuffle can be disabled.
- `queueOrderBeforeShuffle` remains session-only (matches existing plain-shuffle behavior),
  so a smart→off after relaunch restores shuffled-originals order rather than the pristine
  original — no regression versus today.
