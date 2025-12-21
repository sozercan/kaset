# Apple Foundation Models Integration Plan

Integrate Apple's on-device Foundation Models framework (macOS 26+) into Kaset for natural language music control, smart playlist management, and contextual lyrics features—with full graceful degradation for users without Apple Intelligence.

## Steps

### 1. Create `FoundationModelsService`
**Location:** `Core/Services/AI/FoundationModelsService.swift`

- `@MainActor @Observable` singleton following existing patterns in `Core/Services/Protocols.swift`
- Include `availability` published property, `warmup()` for background session init, and `isAvailable` computed property
- Call `warmup()` from `App/KasetApp.swift` in `.task` modifier on launch

### 2. Define `@Generable` Types
**Location:** `Core/Models/AI/`

- `MusicIntent` — enum-style struct with `.play(query)`, `.queue(query)`, `.shuffle(scope)`, `.like`, `.skip`
- `PlaylistChanges` — struct with `removals: [String]`, `reorderedIds: [String]?`, `reasoning: String`
- `LyricsSummary` — struct with `themes: [String]`, `mood: String`, `explanation: String`

### 3. Build `MusicSearchTool`
**Location:** `Core/Services/AI/Tools/MusicSearchTool.swift`

- Conform to `Tool` protocol
- Arguments: `@Generable struct { query: String, type: SearchFilter }`
- Returns formatted search results from `YTMusicClient`
- Model uses this to ground responses in real catalog data rather than hallucinating song IDs

### 4. Create `CommandBarView`
**Location:** `Views/macOS/CommandBarView.swift`

- Floating panel accessible via Cmd+K shortcut
- Parse input via `LanguageModelSession` → `MusicIntent`
- Map intents to `PlayerService`/`YTMusicClient` actions
- Include loading state, error display, and "Search instead" fallback button

### 5. Add "Refine Playlist" Feature
**Location:** `Views/macOS/PlaylistDetailView.swift`

- Send first 50 track titles + user prompt to session
- Display `PlaylistChanges` result as a diff view (removals highlighted, drag to reorder)
- User confirms before applying changes via `YTMusicClient`

### 6. Enhance Lyrics Panel
**Location:** `Views/macOS/LyricsPanel.swift`

- Add "Explain" button
- Pass `Song.title`, `Song.artists`, and `Lyrics.text` to session
- Display `LyricsSummary` in a popover or inline section below lyrics

### 7. Implement `.requiresIntelligence()` ViewModifier
**Location:** `Core/Utilities/IntelligenceModifier.swift`

- Check `FoundationModelsService.shared.isAvailable`
- Hide or dim AI-powered buttons (Command Bar trigger, Refine Playlist, Explain Lyrics) when unavailable
- Show tooltip: "Requires Apple Intelligence"

### 8. Add "Intelligence" Section in Settings
**Location:** `Views/macOS/SettingsView.swift` (new or extend existing)

- Toggle to disable AI features even if available
- "Clear Context" button to reset `LanguageModelSession`
- Link to Apple Intelligence system preferences

## Further Considerations

### Chunking Strategy for Large Playlists
For playlists >50 tracks, offer "Refine first 50" or let the model use a `PlaylistQueryTool` to fetch songs by criteria (e.g., "get slowest 10 songs") instead of dumping all titles.

### Streaming Responses
For lyrics explanation, consider using `LanguageModelSession.streamResponse(to:)` to show text as it generates—feels faster and more interactive.

### Localization
Foundation Models supports multiple languages. Add a note in the Settings Intelligence section that AI responses follow system language, or allow override.