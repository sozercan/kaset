# ADR-0008: Nonisolated Network Helpers for MainActor Classes

## Status

Accepted

## Context

`YTMusicClient` is annotated with `@MainActor` because it needs to:
1. Access `@MainActor`-isolated services (`AuthService`, `WebKitManager`)
2. Be easily consumed by SwiftUI views and `@Observable` ViewModels

However, this caused **UI hitches** during API calls because:
- `URLSession.data(for:)` suspends but resumes on the main actor
- `JSONSerialization.jsonObject(with:)` runs synchronously on the main actor
- Large responses (Home page, playlists with 100+ tracks) block the main thread for 50-200ms

Profiling with Instruments confirmed main thread blocking during navigation and scrolling.

## Decision

We introduce a **nonisolated static helper** that performs network I/O off the main actor:

```swift
@MainActor
final class YTMusicClient {
    // ...
    
    private func performRequest(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        // Build request on main actor (needs auth headers from WebKitManager)
        let request = try await buildRequest(endpoint, body: body)
        
        // Perform network I/O OFF the main thread
        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        
        // Handle result back on main actor
        switch result {
        case let .success(data):
            // JSON parsing is fast (<5ms for typical responses)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.authService.sessionExpired()
            throw YTMusicError.authExpired
        // ... other cases
        }
    }
    
    /// Result type uses only Sendable types.
    private enum NetworkResult: Sendable {
        case success(Data)  // Data is Sendable, [String: Any] is NOT
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }
    
    /// Nonisolated helper - runs on cooperative thread pool.
    nonisolated private static func performNetworkRequest(
        request: URLRequest,
        session: URLSession
    ) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)
            // ... handle response, return NetworkResult
        } catch {
            return .networkError(error)
        }
    }
}
```

### Key Constraints

1. **`[String: Any]` is not `Sendable`** — We cannot return parsed JSON from a nonisolated function. We return `Data` instead and parse on the main actor.

2. **JSON parsing remains on main actor** — This is acceptable because:
   - `JSONSerialization` is very fast for typical response sizes (~5-15ms)
   - URLSession already decompresses gzip/deflate on background threads
   - The expensive part (network I/O, decompression) now happens off-thread

3. **Result enum for error handling** — We use an enum instead of throwing because:
   - Error handling logic needs main actor access (`authService.sessionExpired()`)
   - Cleaner than catching and re-throwing across actor boundaries

## Consequences

### Positive

- **Eliminates UI hitches** during API calls
- **Pattern is reusable** for other `@MainActor` services that need network access
- **Minimal code change** — Only the network layer is affected, no changes to callers
- **Type-safe** — Compiler enforces Sendable constraints

### Negative

- **Slightly more code** — Enum wrapper and switch statement vs. direct return
- **Two-phase approach** — Request building on main actor, execution off-thread, result handling on main actor

### Neutral

- **JSON parsing still on main actor** — Acceptable for our response sizes; could be moved to nonisolated parser functions if responses grow significantly larger

## Alternatives Considered

### 1. Remove @MainActor from YTMusicClient

**Rejected** — Would require:
- Making all callers handle actor isolation manually
- Changing `AuthService` and `WebKitManager` access patterns
- Risk of data races in cookie/auth handling

### 2. Use Task.detached for parsing

**Rejected** — Breaks structured concurrency, makes cancellation harder, and still requires Sendable boundary handling.

### 3. Use Codable with Sendable types

**Rejected** — YouTube Music API returns deeply nested, inconsistent JSON. Codable models would be fragile and require constant updates. The current parser approach with `[String: Any]` is more resilient.

## References

- [SE-0302: Sendable and @Sendable closures](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)
- [WWDC21: Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)
