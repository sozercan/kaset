---
name: api-exploration
description: Use when a task needs a new or modified YouTube Music API call, response parser validation, authenticated endpoint investigation, or fixture capture; explore endpoints with `swift run api-explorer` before changing production code.
metadata:
  short-description: Explore YouTube Music APIs
---

# API Exploration

## Workflow

1. Run `swift run api-explorer auth` if the task touches sign-in-backed endpoints.
2. Check what already exists with `swift run api-explorer list`.
3. Probe the endpoint with `browse`, `action`, or `continuation` before touching production code. If the explorer can't express the request you need, add that capability to `Sources/APIExplorer/main.swift`.
4. Save representative payloads with `-o` when parser work or regression tests need fixtures. `-o` and `-v` emit the raw response, which can include account names, emails, and channel IDs: write captures outside the repo, and redact them before they go into `Tests/KasetTests/Fixtures/` or get quoted in your output.
5. Update `docs/api-discovery.md` when you confirm a new endpoint, parameter, or auth constraint.

`action` sends a real request as the signed-in user. Read-only actions such as `search` are fine; for anything that changes account data (likes, playlist edits, subscriptions), prefer a captured, sanitized response or a disposable resource, and get explicit approval from the human before sending it live.

## Common Commands

```bash
swift run api-explorer auth
swift run api-explorer list
swift run api-explorer browse FEmusic_home -v
swift run api-explorer browse FEmusic_liked_playlists -v
swift run api-explorer action search '{"query":"never gonna give you up"}'
```

## Landmarks

- `Sources/APIExplorer/main.swift`
- `docs/api-discovery.md`
- `Tests/KasetTests/Fixtures/`

Authenticated exploration reads the debug cookie export from `~/Library/Application Support/Kaset/cookies.dat`.
