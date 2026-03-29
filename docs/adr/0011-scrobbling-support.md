# ADR-0011: Scrobbling Support (Last.fm)

## Status

Accepted

## Context

Kaset currently has no way to report listening activity to external services. Users who use Last.fm for tracking their music history cannot get scrobbles from Kaset. Adding scrobbling support requires:

1. **API key security** — Last.fm API requires a shared secret for signing requests. Embedding secrets in the app binary is a security risk.
2. **Offline resilience** — Scrobbles should survive app crashes and network outages.
3. **Accurate play tracking** — Only tracks that meet listening thresholds should be scrobbled (pauses and seeks must not inflate play time).
4. **Extensibility** — Future services (ListenBrainz, Libre.fm) should be easy to add.

## Decision

### Architecture

Implement scrobbling with three layers:

1. **`ScrobbleServiceProtocol`** — A protocol that defines the contract for any scrobbling backend (authenticate, now playing, scrobble, validate session). `LastFMService` is the first conforming implementation.

2. **`ScrobblingCoordinator`** — An `@MainActor @Observable` service that polls `PlayerService` (matching the `NotificationService` polling pattern at 500ms intervals), tracks accumulated play time, detects track changes, and triggers scrobbles when thresholds are met.

3. **`ScrobbleQueue`** — A persistent JSON queue (`~/Library/Application Support/Kaset/scrobble-queue.json`) that ensures every scrobble is written to disk before network submission.

### Cloudflare Worker Proxy

A lightweight Cloudflare Worker proxies all Last.fm API calls:
- The app sends unsigned JSON requests to the Worker
- The Worker adds `api_key` and computes `api_sig` (MD5 of sorted params + shared secret)
- The Worker forwards signed requests to `ws.audioscrobbler.com/2.0/`
- API key and shared secret live **only** in the Worker's environment variables — never in the app binary

This means the app only needs to know the Worker URL. Even if discovered, callers can only scrobble (no destructive actions).

### Scrobble Threshold

A track is scrobbled when accumulated play time reaches **50% of duration** or **240 seconds**, whichever comes first. These values are configurable in Settings. Accumulated play time only counts actual playback (pauses and seeks do not inflate the counter).

### Authentication Flow

1. App requests an auth token from the Worker (`GET /auth/token`)
2. App opens Last.fm authorization URL in browser
3. App polls the Worker (`GET /auth/session?token=X`) every 2s for up to 120s
4. On success, session key and username are stored in Keychain

### Credential Storage

Session keys are stored in macOS Keychain using the Security framework (`kSecClassGenericPassword`), not in UserDefaults, since they are sensitive authentication tokens.

## Consequences

### Positive
- **No secrets in the binary** — API key and shared secret never ship in the app
- **Offline resilient** — Queue-first design survives crashes and restarts
- **Accurate tracking** — Accumulated play time prevents inflated scrobbles
- **Extensible** — Protocol-based design makes adding ListenBrainz straightforward
- **Testable** — `ScrobbleServiceProtocol` enables mocking; queue uses injectable directories
- **Consistent patterns** — Follows existing `NotificationService` polling and `@MainActor @Observable` patterns

### Negative
- **Worker dependency** — Requires a deployed Cloudflare Worker (adds operational overhead)
- **Polling overhead** — 500ms polling adds minimal CPU usage (same as existing `NotificationService`)
- **Keychain complexity** — Direct Security framework usage is more complex than UserDefaults

### Neutral
- Queue file size is negligible (each scrobble entry is ~200 bytes; 1000 pending scrobbles < 200KB)
- Scrobbles older than 14 days are automatically pruned (Last.fm rejects them anyway)
