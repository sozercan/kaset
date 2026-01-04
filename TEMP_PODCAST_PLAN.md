# Podcast Feature Implementation Plan

> **Status**: Planning Complete  
> **Created**: January 2, 2026  
> **Branch**: TBD (suggest: `feature/podcasts`)

---

## Executive Summary

Add podcast discovery, playback, and progress tracking to Kaset. Podcasts will appear as a top-level sidebar item with full discovery support via `FEmusic_podcasts` and show detail pages.

---

## Requirements Summary

| Requirement | Decision |
|-------------|----------|
| Scope | Full podcast discovery |
| Progress Tracking | Auto via WebView (display with progress bar) |
| Library Integration | None (sidebar only) |
| Sidebar Position | Top-level (alongside Home, Explore, Charts) |
| Episode Autoplay | Yes (queue behavior like songs) |
| Search Integration | Separate "Podcasts" section in results |
| Podcast Detection | Via `musicMultiRowListItemRenderer` + `playbackProgress` |
| Progress UI | Progress bar showing % listened (Apple Podcasts style) |

---

## API Endpoints

### Validated Endpoints ✅

| Endpoint | Browse ID | Auth | Status |
|----------|-----------|------|--------|
| Podcasts Discovery | `FEmusic_podcasts` | 🌐 | HTTP 200 |
| Podcast Show Detail | `MPSPP{id}` | 🌐 | HTTP 200 |
| Episode Playback | `next` with `videoId` | 🌐 | HTTP 200 |

### Progress Tracking

Progress syncs automatically via WebView's `stats/watchtime` calls. The API returns:
- `playbackProgressPercentage`: 0-100 (for progress bar)
- `playedText`: "Played" or remaining time
- `durationText`: Total duration

---

## Data Models

### PodcastShow

```swift
struct PodcastShow: Identifiable, Sendable, Hashable {
    let id: String              // browseId (MPSPP...)
    let title: String
    let author: String?
    let description: String?
    let thumbnailURL: URL?
    let episodeCount: Int?
}
```

### PodcastEpisode

```swift
struct PodcastEpisode: Identifiable, Sendable, Hashable {
    let id: String              // videoId
    let title: String
    let showTitle: String?      // secondTitle
    let showBrowseId: String?   // for navigation back to show
    let description: String?
    let thumbnailURL: URL?
    let publishedDate: String?  // "3d ago", "Dec 28, 2025"
    let duration: String?       // "36 min", "1:11:19"
    let durationSeconds: Int?   // for progress calculation
    let playbackProgress: Double // 0.0-1.0
    let isPlayed: Bool
}
```

### PodcastSection (for discovery page)

```swift
struct PodcastSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [PodcastSectionItem]
}

enum PodcastSectionItem: Sendable {
    case show(PodcastShow)
    case episode(PodcastEpisode)
}
```

---

## API Methods

```swift
extension YTMusicClient {
    /// Fetch podcasts discovery page (FEmusic_podcasts)
    func getPodcasts() async throws -> [PodcastSection]
    
    /// Fetch podcast show detail with episodes (MPSPP{id})
    func getPodcastShow(browseId: String) async throws -> PodcastShowDetail
    
    /// Fetch more episodes via continuation token
    func getPodcastEpisodes(continuation: String) async throws -> PodcastEpisodesContinuation
}
```

---

## Podcast Detection

When parsing playlists/content, detect podcasts by:

1. **Browse ID prefix**: `MPSPP` = podcast show
2. **Episode renderer**: `musicMultiRowListItemRenderer` (songs use `musicResponsiveListItemRenderer`)
3. **playbackProgress field**: Only present on podcast episodes
4. **secondTitle field**: Only on podcast episodes (contains show name)

---

## Implementation Phases

### Phase 1: Models & Parser (4-6 hours)

**Files to Create:**
- [ ] `Core/Models/Podcast.swift` — PodcastShow, PodcastEpisode, PodcastSection
- [ ] `Core/Services/API/Parsers/PodcastParser.swift` — Parse discovery & show detail

**Exit Criteria:**
- `xcodebuild build` succeeds
- Unit tests pass with mock JSON fixtures

---

### Phase 2: API Client (2-3 hours)

**Files to Modify:**
- [ ] `Core/Services/API/YTMusicClient.swift` — Add podcast methods

**Methods:**
```swift
func getPodcasts() async throws -> [PodcastSection]
func getPodcastShow(browseId: String) async throws -> PodcastShowDetail
func getPodcastEpisodes(continuation: String) async throws -> PodcastEpisodesContinuation
```

**Exit Criteria:**
- API methods compile
- Can fetch real data from YouTube Music API

---

### Phase 3: ViewModels (2-3 hours)

**Files to Create:**
- [ ] `Core/ViewModels/PodcastsViewModel.swift` — Discovery page state
- [ ] `Core/ViewModels/PodcastShowViewModel.swift` — Show detail state

**Pattern:**
```swift
@MainActor
@Observable
final class PodcastsViewModel {
    var sections: [PodcastSection] = []
    var loadingState: LoadingState = .idle
    
    func loadPodcasts() async
}

@MainActor
@Observable
final class PodcastShowViewModel {
    var show: PodcastShowDetail?
    var episodes: [PodcastEpisode] = []
    var continuationToken: String?
    var loadingState: LoadingState = .idle
    
    func loadShow(browseId: String) async
    func loadMoreEpisodes() async
}
```

**Exit Criteria:**
- ViewModels compile with `@MainActor`, `@Observable`
- Loading states work correctly

---

### Phase 4: Views (4-6 hours)

**Files to Create:**
- [ ] `Views/macOS/PodcastsView.swift` — Discovery grid
- [ ] `Views/macOS/PodcastShowView.swift` — Show detail with episodes

**Files to Modify:**
- [ ] `Views/macOS/Sidebar.swift` — Add Podcasts navigation item
- [ ] `Views/macOS/MainWindow.swift` — Add navigation destinations

**UI Components:**

#### PodcastsView (Discovery)
```
┌────────────────────────────────────────────────────┐
│ Podcasts                                           │
├────────────────────────────────────────────────────┤
│ Start exploring                              ────▸ │
│ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐       │
│ │  show  │ │  show  │ │  show  │ │  show  │       │
│ │ thumb  │ │ thumb  │ │ thumb  │ │ thumb  │       │
│ │  Name  │ │  Name  │ │  Name  │ │  Name  │       │
│ └────────┘ └────────┘ └────────┘ └────────┘       │
├────────────────────────────────────────────────────┤
│ Popular episodes                             ────▸ │
│ ┌──────────────────────────────────────────────┐  │
│ │ 🎙️ Episode Title                    36 min  │  │
│ │    Show Name • 3d ago        ▓▓▓▓▓▓▓░░░░░░░ │  │
│ └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

#### PodcastShowView (Detail)
```
┌────────────────────────────────────────────────────┐
│ ┌──────────┐  Show Title                          │
│ │          │  Author Name                         │
│ │ Artwork  │  Description text preview...         │
│ │          │                                      │
│ └──────────┘  [▶ Play] [⋯ Shuffle] [♡ Save]      │
├────────────────────────────────────────────────────┤
│ Episodes                                           │
│ ┌──────────────────────────────────────────────┐  │
│ │ 🎙️ Episode 1                        36 min  │  │
│ │    Description preview...    ▓▓▓▓▓▓▓░░░░░░░ │  │
│ └──────────────────────────────────────────────┘  │
│ ┌──────────────────────────────────────────────┐  │
│ │ 🎙️ Episode 2                      1:11:19   │  │
│ │    Description preview...           Played ✓ │  │
│ └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

#### Episode Row Component (Progress Bar)
```swift
struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(episode.title)
                Spacer()
                Text(episode.duration ?? "")
            }
            
            if let description = episode.description {
                Text(description)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            
            // Progress bar (Apple Podcasts style)
            if episode.playbackProgress > 0 {
                ProgressView(value: episode.playbackProgress)
                    .tint(episode.isPlayed ? .secondary : .accentColor)
            }
        }
    }
}
```

**Exit Criteria:**
- Views render with real data
- Navigation works from sidebar → discovery → show detail → episode playback
- Liquid Glass styling applied

---

### Phase 5: Playback Integration (2-3 hours)

**Files to Modify:**
- [ ] `Core/Services/Player/PlayerService.swift` — Handle podcast context

**Requirements:**
- Tapping episode plays via WebView (uses existing `videoId` playback)
- Auto-play next episode in show
- Now Playing shows episode title + show name

**Exit Criteria:**
- Episode playback works
- Queue shows upcoming episodes

---

### Phase 6: Search Integration (2-3 hours)

**Files to Modify:**
- [ ] `Core/Services/API/Parsers/SearchResponseParser.swift` — Detect podcast items
- [ ] `Core/ViewModels/SearchViewModel.swift` — Separate podcast results
- [ ] `Views/macOS/SearchView.swift` — Display "Podcasts" section

**Detection in Search:**
```swift
// Check pageType in navigation endpoint
if browseEndpoint.pageType == "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE" {
    // Parse as PodcastShow
}
```

**Exit Criteria:**
- Searching for "huberman" shows podcast results in separate section
- Tapping podcast result navigates to PodcastShowView

---

## Files Summary

### New Files (7)

| File | Purpose |
|------|---------|
| `Core/Models/Podcast.swift` | Data models |
| `Core/Services/API/Parsers/PodcastParser.swift` | Response parsing |
| `Core/ViewModels/PodcastsViewModel.swift` | Discovery state |
| `Core/ViewModels/PodcastShowViewModel.swift` | Show detail state |
| `Views/macOS/PodcastsView.swift` | Discovery UI |
| `Views/macOS/PodcastShowView.swift` | Show detail UI |
| `Tests/KasetTests/PodcastParserTests.swift` | Parser tests |

### Modified Files (5)

| File | Changes |
|------|---------|
| `Core/Services/API/YTMusicClient.swift` | Add podcast methods |
| `Core/Services/API/Parsers/SearchResponseParser.swift` | Detect podcasts |
| `Views/macOS/Sidebar.swift` | Add Podcasts nav item |
| `Views/macOS/MainWindow.swift` | Add navigation destinations |
| `Views/macOS/SearchView.swift` | Podcasts section |

---

## Estimated Effort

| Phase | Hours | Priority |
|-------|-------|----------|
| Phase 1: Models & Parser | 4-6 | High |
| Phase 2: API Client | 2-3 | High |
| Phase 3: ViewModels | 2-3 | High |
| Phase 4: Views | 4-6 | High |
| Phase 5: Playback | 2-3 | High |
| Phase 6: Search | 2-3 | Medium |
| **Total** | **16-24** | |

---

## Test Fixtures Needed

Save these for parser tests:

```bash
# Discovery page
./Tools/api-explorer.swift browse FEmusic_podcasts -o Tests/KasetTests/Fixtures/podcasts_discovery.json

# Show detail
./Tools/api-explorer.swift browse MPSPPLbuShuUyOZf38uFsn2BTTeUOiqpcH0fNS -o Tests/KasetTests/Fixtures/podcast_show.json
```

---

## Open Questions

None — all clarifying questions answered.

---

## Next Steps

1. Create feature branch: `git checkout -b feature/podcasts`
2. Begin Phase 1: Models & Parser
3. Commit after each phase with passing tests
