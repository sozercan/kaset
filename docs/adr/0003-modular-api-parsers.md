# ADR-0003: Modular API Response Parsers

## Status

Accepted

## Context

`YTMusicClient.swift` grew to ~1,700 lines, mixing networking logic with complex JSON parsing. The YouTube Music API returns deeply nested, inconsistent JSON structures that require extensive navigation code.

Problems with the monolithic approach:
1. **Single Responsibility violation** - Networking and parsing are different concerns
2. **Difficult testing** - Can't test parsing without network mocks
3. **Poor maintainability** - Finding relevant parsing code is challenging
4. **Code duplication** - Similar extraction patterns repeated throughout

## Decision

Extract parsing logic into a dedicated `Parsers/` module with specialized parsers for each response type:

```
Sources/Kaset/Services/API/
├── YTMusicClient.swift          # Networking only (~370 lines)
├── Parsers/
│   ├── ParsingHelpers.swift     # Shared extraction utilities
│   ├── HomeResponseParser.swift
│   ├── SearchResponseParser.swift
│   ├── PlaylistParser.swift
│   └── ArtistParser.swift
```

### Key Design Choices

1. **Static enum-based parsers** - No state, pure functions for parsing
2. **Shared helpers** - `ParsingHelpers` centralizes common patterns (thumbnail extraction, artist parsing, duration parsing)
3. **Internal visibility** - Parsers are internal to the module, YTMusicClient is the public interface

### Music model boundaries

- Inline album and artist metadata can identify content for display without identifying a navigable page. Album navigation requires a server browse ID (`MPRE` or `OLAK`), not a generated fallback. Artists distinguish public `UC` channel IDs from `MPLAUC` library browse IDs; sharing and subscription operations use the public channel identity. Generated display IDs must not become browse targets.
- A playlist row's `playlistSetVideoId` is an occurrence ID, not the song's playback ID. Use it for removal so two copies of the same song remain distinguishable. Album rows can link to an official music video while the credits menu links to its audio counterpart. Retain the row's playable ID and expose the credits ID separately; `Song.preferredAudioVideoId` falls back to the row's ID when no distinct recording was identified.
- Account-generated collections are not ordinary subscribable playlists, and their data can require the signed-in account even when playback is otherwise available. For paginated playlist details, prefer the server's total count over the number of rows loaded.
- Moods and genres are browse destinations, not playlists. Preserve their `browseId` and `params` separately. Decode the combined ID only for older playlist-like values without a structured endpoint.

## Consequences

### Positive
- **Reduced complexity** - YTMusicClient from 1,700 to 370 lines
- **Testable parsing** - Unit tests with mock JSON data
- **Clear organization** - Each parser handles one response type
- **DRY code** - Common patterns in ParsingHelpers
- **Easier debugging** - Parsing failures localized to specific parser

### Negative
- **More files** - 5 new files to maintain
- **Indirection** - Tracing parsing requires jumping between files
- **Import overhead** - Parsers must import model types

### Metrics
| Metric | Before | After |
|--------|--------|-------|
| YTMusicClient lines | 1,766 | 370 |
| Parsing test files | 0 | 4 |
| Cyclomatic complexity | High | Reduced |
