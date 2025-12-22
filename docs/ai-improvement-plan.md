# Foundation Models Integration Improvement Plan

This document outlines improvements to the Kaset app's Foundation Models integration based on a deep dive into:
- [Apple's Official Documentation](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models)
- [The Ultimate Guide to Foundation Models Framework](https://azamsharp.com/2025/06/18/the-ultimate-guide-to-the-foundation-models-framework.html)

## Current Implementation Summary

### What We Have
| Component | Status | Notes |
|-----------|--------|-------|
| `FoundationModelsService` | ✅ Good | Singleton service with availability checking, session creation |
| `@Generable` Models | ✅ Good | `MusicIntent`, `MusicQuery`, `LyricsSummary`, `QueueIntent`, etc. |
| Tools | ✅ Basic | `MusicSearchTool`, `QueueTool` for grounding AI responses |
| Availability Checking | ✅ Good | Handles all unavailable states |
| View Modifier | ✅ Good | `RequiresIntelligenceModifier` for conditional UI |
| Warmup | ⚠️ Partial | Uses simple "Hello" prompt, not `prewarm()` API |
| Streaming | ❌ Missing | All responses are blocking (full wait) |
| Tests | ❌ Missing | No unit tests for AI components |

### Current Use Cases
1. **Command Bar** - Natural language music commands parsed to `MusicIntent`
2. **Lyrics Explanation** - Song lyrics analyzed to generate `LyricsSummary`
3. **Playlist Refinement** - AI suggestions for playlist changes

---

## Improvement Areas

### 1. 🚀 **Implement Response Streaming**

**Problem**: Users wait for complete AI response before seeing any feedback. This creates perceived lag especially for complex queries.

**Solution**: Use `streamResponse(to:generating:)` for progressive UI updates.

**Files to Change**:
- [CommandBarView.swift](../Views/macOS/CommandBarView.swift)
- [LyricsView.swift](../Views/macOS/LyricsView.swift)
- [PlaylistDetailView.swift](../Views/macOS/PlaylistDetailView.swift)

**Implementation Pattern**:
```swift
// Before (blocking)
let response = try await session.respond(to: prompt, generating: LyricsSummary.self)
self.lyricsSummary = response.content

// After (streaming)
let stream = session.streamResponse(to: prompt, generating: LyricsSummary.self)
for try await partialResponse in stream {
    // Update UI progressively with partial data
    self.partialSummary = partialResponse  // Type: LyricsSummary.PartiallyGenerated
}
// Final complete response available after loop
```

**UI Considerations**:
- Show placeholder text while streaming (e.g., "Analyzing..." that progressively fills in)
- For `LyricsSummary`, show mood and themes as they appear
- For `MusicIntent`, streaming may not add much value (action-oriented)

**Priority**: High - Significant UX improvement

---

### 2. 🔥 **Use Proper Prewarm API**

**Problem**: Current warmup sends a dummy "Hello" prompt, wasting tokens and resources.

**Solution**: Use the official `prewarm()` API on `LanguageModelSession`.

**Files to Change**:
- [FoundationModelsService.swift](../Core/Services/AI/FoundationModelsService.swift)

**Implementation**:
```swift
private func preloadSession() async {
    logger.debug("Pre-warming Foundation Models")
    
    let session = LanguageModelSession()
    await session.prewarm()
    
    logger.debug("Foundation Models prewarm complete")
}
```

**Priority**: Medium - Cleaner, more efficient warmup

---

### 3. 📊 **Add Context-Specific Model Tailoring**

**Problem**: We use the same generic session for all AI tasks. Different tasks have different optimal configurations.

**Solution**: Create specialized session factories per use case.

**New Patterns**:

```swift
extension FoundationModelsService {
    /// Session optimized for quick intent parsing
    func createCommandSession(tools: [any Tool]) -> LanguageModelSession? {
        guard isAvailable else { return nil }
        return LanguageModelSession(
            tools: tools,
            instructions: Self.commandInstructions
        )
    }
    
    /// Session optimized for longer-form analysis
    func createAnalysisSession() -> LanguageModelSession? {
        guard isAvailable else { return nil }
        return LanguageModelSession(
            instructions: Self.analysisInstructions
        )
    }
    
    /// Session for conversational multi-turn interactions
    func createConversationalSession() -> LanguageModelSession? {
        guard isAvailable else { return nil }
        return LanguageModelSession(
            instructions: Self.conversationalInstructions
        )
    }
}
```

**Priority**: Medium - Better separation of concerns

---

### 4. ⚡ **Optimize @Generable Models for Performance**

**Problem**: Models include properties that aren't always needed, increasing generation time. Per the guide: "the model populates all properties... regardless of whether they're used in the UI."

**Solution**: Create task-specific minimal models.

**Example - Split MusicIntent**:

```swift
// For simple playback commands (skip, pause, resume)
@Generable
struct SimplePlaybackIntent: Sendable {
    @Guide(description: "Action: skip, pause, resume, like, dislike")
    let action: SimpleAction
}

// For search-based commands (play jazz, queue rock songs)
@Generable  
struct SearchPlaybackIntent: Sendable {
    @Guide(description: "Action: play, queue, search")
    let action: SearchAction
    
    @Guide(description: "Search query or artist name")
    let query: String
    
    @Guide(description: "Genre if mentioned")
    let genre: String
    
    @Guide(description: "Mood if mentioned")
    let mood: String
}
```

**Two-Stage Parsing**:
1. First pass: Classify intent type (simple vs search vs queue)
2. Second pass: Parse with appropriate minimal model

**Priority**: Medium - Performance optimization

---

### 5. 🛡️ **Add Robust Error Handling**

**Problem**: Limited error handling beyond generic catch blocks.

**Solution**: Handle specific Foundation Models errors with user-friendly messages.

**Implementation**:
```swift
do {
    let response = try await session.respond(to: prompt, generating: MusicIntent.self)
    await executeIntent(response.content)
} catch LanguageModelSession.GenerationError.exceededContextWindowSize(let info) {
    logger.error("Context window exceeded: \(info)")
    errorMessage = "That request was too complex. Try a shorter command."
} catch LanguageModelSession.GenerationError.cancelled {
    logger.info("Generation was cancelled")
    // User cancelled, no error message needed
} catch LanguageModelSession.GenerationError.guardedContent {
    logger.warning("Content was blocked by safety guardrails")
    errorMessage = "I can't help with that request."
} catch {
    logger.error("Generation failed: \(error)")
    errorMessage = "Something went wrong. Please try again."
}
```

**Priority**: High - Better user experience

---

### 6. 📐 **Implement GenerationOptions Tuning**

**Problem**: We don't customize generation parameters for different use cases.

**Solution**: Use `GenerationOptions` for task-specific tuning.

**Implementation**:
```swift
// For creative tasks (lyrics explanation)
let creativeOptions = GenerationOptions(temperature: 1.5)

// For structured parsing (commands)
let preciseOptions = GenerationOptions(temperature: 0.5)

let response = try await session.respond(
    to: prompt, 
    generating: LyricsSummary.self,
    options: creativeOptions
)
```

**Priority**: Low - Fine-tuning optimization

---

### 7. 🧪 **Add Unit Test Coverage**

**Problem**: No tests for AI components.

**Solution**: Create comprehensive test suite.

**New Test File**: `Tests/KasetTests/FoundationModelsTests.swift`

```swift
@available(macOS 26.0, *)
final class FoundationModelsTests: XCTestCase {
    
    // MARK: - MusicIntent Tests
    
    func testMusicIntentBuildSearchQuery_artistOnly() {
        let intent = MusicIntent(
            action: .play,
            query: "Beatles songs",
            shuffleScope: "",
            artist: "Beatles",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        
        let query = intent.buildSearchQuery()
        XCTAssertTrue(query.contains("Beatles"))
        XCTAssertTrue(query.contains("songs"))
    }
    
    func testMusicIntentBuildSearchQuery_moodAndGenre() {
        let intent = MusicIntent(
            action: .play,
            query: "",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )
        
        let query = intent.buildSearchQuery()
        XCTAssertEqual(query, "jazz chill songs")
    }
    
    func testContentSourceSuggestion_artistQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "Taylor Swift",
            shuffleScope: "",
            artist: "Taylor Swift",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        
        XCTAssertEqual(intent.suggestedContentSource(), .search)
    }
    
    func testContentSourceSuggestion_moodQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "chill music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )
        
        XCTAssertEqual(intent.suggestedContentSource(), .moodsAndGenres)
    }
    
    // MARK: - MusicQuery Tests
    
    func testMusicQueryBuildSearchQuery() {
        let query = MusicQuery(
            searchTerm: "",
            artist: "Coldplay",
            genre: "rock",
            mood: "",
            activity: "",
            era: "2000s",
            version: "",
            language: "",
            contentRating: "",
            count: 0
        )
        
        let result = query.buildSearchQuery()
        XCTAssertTrue(result.contains("Coldplay"))
        XCTAssertTrue(result.contains("rock"))
        XCTAssertTrue(result.contains("2000s"))
    }
}
```

**Priority**: High - Quality assurance

---

### 8. 🔧 **Add New Tools**

**Current Tools**: `MusicSearchTool`, `QueueTool`

**Proposed New Tools**:

#### a. `PlaylistTool` - Get playlist contents for refinement
```swift
@available(macOS 26.0, *)
struct PlaylistTool: Tool {
    let client: any YTMusicClientProtocol
    
    let name = "getPlaylistContents"
    let description = """
    Gets the contents of a playlist by ID.
    Use this to understand playlist contents before suggesting changes.
    """
    
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The playlist ID to fetch")
        let playlistId: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        let playlist = try await client.fetchPlaylist(id: arguments.playlistId)
        // Format and return playlist info
    }
}
```

#### b. `NowPlayingTool` - Get current track info
```swift
@available(macOS 26.0, *)
struct NowPlayingTool: Tool {
    let playerService: PlayerService
    
    let name = "getNowPlaying"
    let description = """
    Gets information about the currently playing track.
    Use this to understand context for commands like "play more like this".
    """
    
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Whether to include lyrics if available")
        let includeLyrics: Bool
    }
    
    // Implementation...
}
```

#### c. `LibraryTool` - Access user's library
```swift
@available(macOS 26.0, *)
struct LibraryTool: Tool {
    let client: any YTMusicClientProtocol
    
    let name = "getUserLibrary"
    let description = """
    Gets the user's saved music (liked songs, playlists, albums).
    Use this for commands like "shuffle my library" or "play my favorites".
    """
    
    // Implementation...
}
```

**Priority**: Medium - Extends AI capabilities

---

### 9. 📱 **Multi-Turn Conversation Support**

**Problem**: Each command creates a fresh session. Users can't have conversational interactions.

**Solution**: Maintain session state for conversational flows.

**Use Case**: "Play jazz" → "Make it more upbeat" → "Add to queue instead"

**Implementation**:
```swift
@MainActor
@Observable
final class ConversationalCommandService {
    private var session: LanguageModelSession?
    private var conversationContext: [String] = []
    
    func startConversation() {
        self.session = FoundationModelsService.shared.createConversationalSession()
    }
    
    func processMessage(_ message: String) async throws -> MusicIntent {
        guard let session else {
            throw ConversationError.noActiveSession
        }
        
        // Session retains context from previous calls
        let response = try await session.respond(to: message, generating: MusicIntent.self)
        conversationContext.append(message)
        
        return response.content
    }
    
    func endConversation() {
        session = nil
        conversationContext.removeAll()
    }
}
```

**Priority**: Low - Nice-to-have feature

---

### 10. 📈 **Add Transcript Logging for Debugging**

**Problem**: Hard to debug why AI made certain decisions.

**Solution**: Log the `Transcript` from sessions.

**Implementation**:
```swift
let response = try await session.respond(to: prompt, generating: MusicIntent.self)

// Log transcript for debugging
for entry in session.transcript.entries {
    switch entry {
    case .prompt(let prompt):
        logger.debug("📝 Prompt: \(prompt)")
    case .response(let response):
        logger.debug("🤖 Response: \(response)")
    case .toolCall(let toolCall):
        logger.debug("🔧 Tool called: \(toolCall.name)")
    case .toolResult(let result):
        logger.debug("📤 Tool result: \(result)")
    @unknown default:
        break
    }
}
```

**Priority**: Medium - Debugging/development aid

---

## Implementation Phases

### Phase 1: Foundation (Priority: High) ⏱️ ~1 day
| Task | Files |
|------|-------|
| Improve error handling | `CommandBarView.swift`, `LyricsView.swift`, `PlaylistDetailView.swift` |
| Use proper `prewarm()` API | `FoundationModelsService.swift` |
| Add unit tests for existing models | New: `FoundationModelsTests.swift` |

**Exit Criteria**:
- All AI error cases handled gracefully with user-friendly messages
- Warmup uses official API
- `MusicIntent` and `MusicQuery` have >80% test coverage

### Phase 2: Streaming (Priority: High) ⏱️ ~1-2 days
| Task | Files |
|------|-------|
| Add streaming to `LyricsView` | `LyricsView.swift` |
| Add streaming UI components | New: `StreamingTextView.swift` |
| Update `LyricsSummary` to support partial display | `LyricsSummary.swift` |

**Exit Criteria**:
- Lyrics explanation shows progressive text as it generates
- User can see mood/themes appear in real-time
- No regression in existing functionality

### Phase 3: Optimization (Priority: Medium) ⏱️ ~1 day
| Task | Files |
|------|-------|
| Split `MusicIntent` into specialized models | `MusicIntent.swift`, new files |
| Add `GenerationOptions` tuning | `FoundationModelsService.swift` |
| Create specialized session factories | `FoundationModelsService.swift` |

**Exit Criteria**:
- Simple commands (skip, pause) parse faster
- Complex queries use appropriate models
- Measurable improvement in response time

### Phase 4: Enhanced Tools (Priority: Medium) ⏱️ ~2 days
| Task | Files |
|------|-------|
| Implement `NowPlayingTool` | New: `NowPlayingTool.swift` |
| Implement `PlaylistTool` | New: `PlaylistTool.swift` |
| Implement `LibraryTool` | New: `LibraryTool.swift` |
| Add tests for tools | `FoundationModelsTests.swift` |

**Exit Criteria**:
- "Play more like this" uses `NowPlayingTool` to understand context
- Playlist refinement uses `PlaylistTool` for grounded suggestions
- Tools have unit test coverage

### Phase 5: Conversational (Priority: Low) ⏱️ ~2 days
| Task | Files |
|------|-------|
| Implement `ConversationalCommandService` | New file |
| Update CommandBar for multi-turn | `CommandBarView.swift` |
| Add conversation UI (history display) | New: `ConversationHistoryView.swift` |

**Exit Criteria**:
- Users can refine commands conversationally
- Session persists context across messages
- Clear way to start new conversation

---

## Key Learnings from Research

### From Apple Documentation
1. **Token Limit**: 4,096 tokens per session (instructions + prompts + outputs)
2. **Single Request**: Sessions can only handle one request at a time - check `isResponding`
3. **Safety**: Model may decline certain requests - handle gracefully
4. **Instructions vs Prompts**: Instructions are developer-controlled and higher priority

### From Azam Sharp Guide
1. **Streaming Essential**: Always stream for user-facing content - blocking feels slow
2. **Minimize Properties**: Every `@Generable` property is generated even if not displayed
3. **Tool Design**: Tools should return structured strings the model can parse
4. **Prewarm Early**: Call `prewarm()` when you're confident user will use AI features
5. **Property Order**: Put dependent properties last (e.g., summaries after source text)

---

## Known Issues

### 🐛 Mood-Based Search Returns Unrelated Songs

**Problem**: When user says "play something chill," the system correctly parses `mood: "chill"` and routes to Moods & Genres. However, if no matching playlist is found, fallback search for "chill" returns unrelated songs (e.g., "Baby" by Justin Bieber - definitely not chill).

**Root Cause**:
1. Moods & Genres matching uses simple string contains, may miss valid playlists
2. Fallback search query is too generic ("chill" vs "chill music playlist")
3. YouTube Music search doesn't filter by actual mood/energy

**Potential Solutions**:

1. **Improve Search Query for Mood Fallback**:
```swift
// In CommandBarView.playSearchResult()
// Add "music playlist" suffix for mood-only queries
let enhancedQuery = intent.mood.isEmpty ? query : "\(query) music playlist"
```

2. **Expand Moods & Genres Matching**:
```swift
// Add synonym matching
let chillSynonyms = ["chill", "relaxing", "calm", "peaceful", "mellow", "ambient", "lo-fi", "lofi"]
```

3. **Use Explicit Mood Playlists from API**:
- YouTube Music has curated mood playlists (e.g., "FEmusic_moods_and_genres_category_chill")
- Try fetching directly by known browseId patterns

4. **AI-Assisted Filtering** (Future):
- Use Foundation Models to score search results for mood match
- Filter out songs that don't match requested mood

**Priority**: High - Core UX issue

**Files to Change**:
- [CommandBarView.swift](../Views/macOS/CommandBarView.swift) - Search query enhancement
- [MusicIntent.swift](../Core/Models/AI/MusicIntent.swift) - Better query building for moods

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Streaming complicates UI state | Use progressive reveal patterns, test thoroughly |
| Smaller models may lose context | Test query quality with specialized models |
| Tool proliferation | Keep tools focused, document clearly |
| Token limits hit | Monitor transcript size, chunk large requests |
| Model not ready at launch | Show graceful loading state, retry logic |
| Mood search returns wrong content | Improve query building, add playlist suffix |

---

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Time-to-first-token (lyrics) | ~3-5s (blocking) | <1s (streaming) |
| Command parse success rate | Unknown | >90% |
| Test coverage (AI components) | 0% | >80% |
| Error cases with user message | ~50% | 100% |

---

## Next Steps

1. Review this plan with stakeholders
2. Create ADR for streaming implementation decision
3. Begin Phase 1 implementation
4. Measure baseline metrics before optimization

---

*Last Updated: December 21, 2025*
