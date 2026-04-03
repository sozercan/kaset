---
name: api-exploration
description: Use when a task needs a new or modified YouTube Music API call, response parser validation, authenticated endpoint investigation, or fixture capture; explore endpoints with `swift run api-explorer` before changing production code.
metadata:
  short-description: Explore YouTube Music APIs
---

# API Exploration

Use this skill when a task needs a new or modified YouTube Music API call, response parser validation, authenticated endpoint investigation, or fixture capture.

## Guardrails

- Always enhance `Sources/APIExplorer/main.swift`; do not write one-off scripts for endpoint exploration.
- Never commit real cookies, SAPISID values, tokens, or account identifiers. Redact anything sensitive in notes, fixtures, and examples.
- Prefer API endpoints over WebView whenever the functionality already exists in `YTMusicClient`.

## Workflow

1. Start with `swift run api-explorer auth` if the task touches sign-in-backed endpoints.
2. Check what already exists with `swift run api-explorer list`.
3. Probe the endpoint with `browse`, `action`, or `continuation` before touching production code.
4. Save representative payloads with `-o` when parser work or regression tests need fixtures.
5. Update `docs/api-discovery.md` if you confirm a new endpoint, parameter, or auth constraint.

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
