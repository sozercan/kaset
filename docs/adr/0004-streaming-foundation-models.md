# ADR 0004: Streaming Responses for Foundation Models

**Date**: 2025-12-21  
**Status**: Accepted  
**Context**: Foundation Models integration improvement  

## Context

The Kaset app uses Apple's Foundation Models framework for on-device AI features including:
- Natural language command parsing (CommandBar)
- Lyrics explanation and analysis (LyricsView)
- Playlist refinement suggestions (PlaylistDetailView)

The initial implementation used blocking `respond(to:generating:)` calls, which require the user to wait for the complete response before seeing any output. For lyrics explanation, this could mean 3-5 seconds of perceived lag with no feedback.

## Decision

Implement streaming responses using `streamResponse(to:generating:)` for user-facing AI content, specifically lyrics explanation. The streaming API returns `PartiallyGenerated` types that progressively fill in as the model generates output.

### Implementation Pattern

```swift
// Streaming with progressive UI updates
let stream = session.streamResponse(to: prompt, generating: LyricsSummary.self)

for try await partialResponse in stream {
    // partialResponse is LyricsSummary.PartiallyGenerated
    // Properties are optional until fully generated
    self.partialSummary = partialResponse
}

// Convert final partial to complete type
if let final = partialSummary,
   let mood = final.mood,
   let themes = final.themes,
   let explanation = final.explanation {
    self.lyricsSummary = LyricsSummary(themes: themes, mood: mood, explanation: explanation)
}
```

### Where Streaming is Applied

| Feature | Streaming | Rationale |
|---------|-----------|-----------|
| Lyrics Explanation | ✅ Yes | Long-form creative content benefits from progressive display |
| Command Parsing | ❌ No | Intent parsing is fast; streaming adds complexity without benefit |
| Playlist Refinement | ❌ No | Changes are applied atomically after generation |

## Consequences

### Positive

1. **Improved Perceived Performance**: Users see content appearing immediately rather than waiting for complete generation
2. **Better User Feedback**: The streaming state shows "Analyzing..." with progressive content
3. **Aligned with Apple Best Practices**: Official documentation recommends streaming for user-facing content
4. **Reduced Perceived Latency**: First content appears in <1 second vs 3-5 seconds blocking

### Negative

1. **Increased Complexity**: UI must handle both partial and complete states
2. **Memory Usage**: Temporary `PartiallyGenerated` types are kept during streaming
3. **Type Conversion**: Final partial must be converted to complete type manually

### Neutral

1. **No Change for Quick Operations**: Command parsing remains blocking (appropriate for its use case)
2. **Testing**: Streaming behavior harder to unit test (requires integration tests)

## Alternatives Considered

### 1. Keep Blocking Responses
- **Pros**: Simpler code, easier testing
- **Cons**: Poor UX for longer generations, doesn't match user expectations from ChatGPT-like interfaces

### 2. Stream Everything
- **Pros**: Consistent pattern across all AI features
- **Cons**: Overkill for fast operations like command parsing; adds latency from stream setup

### 3. Fake Streaming with Animation
- **Pros**: No API changes needed
- **Cons**: Doesn't actually improve response time; feels artificial

## References

- [Apple Foundation Models Documentation](https://developer.apple.com/documentation/FoundationModels)
- [The Ultimate Guide to Foundation Models Framework](https://azamsharp.com/2025/06/18/the-ultimate-guide-to-the-foundation-models-framework.html)
