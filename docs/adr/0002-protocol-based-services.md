# ADR-0002: Protocol-Based Service Design

## Status

Accepted

## Context

The codebase initially used singletons with `.shared` access pattern for services like `YTMusicClient`, `AuthService`, and `PlayerService`. While simple, this pattern creates challenges:

1. **Testing difficulty** - ViewModels directly reference concrete singletons, making it hard to inject mocks
2. **Tight coupling** - Components depend on implementation details rather than contracts
3. **Hidden dependencies** - Dependencies are not visible in initializers

## Decision

Introduce protocols for all major services and update ViewModels to depend on protocols with default implementations pointing to the shared instance.

```swift
protocol YTMusicClientProtocol: Sendable {
    func getHome() async throws -> HomeResponse
    func search(query: String) async throws -> SearchResponse
    // ...
}

@MainActor @Observable
final class HomeViewModel {
    private let client: YTMusicClientProtocol

    init(client: YTMusicClientProtocol = YTMusicClient.shared) {
        self.client = client
    }
}
```

### Protocols Introduced
- `YTMusicClientProtocol` - API operations
- `AuthServiceProtocol` - Authentication state
- `PlayerServiceProtocol` - Playback control

## Consequences

### Positive
- **Testable ViewModels** - Inject `MockYTMusicClient` in tests
- **Clear contracts** - Protocols document service capabilities
- **Flexible composition** - Easy to swap implementations
- **Explicit dependencies** - Initializers show what's needed

### Negative
- **Boilerplate** - Protocol definitions duplicate method signatures
- **Maintenance** - Changes require updating both protocol and implementation
- **Learning curve** - New contributors must understand the pattern

### Trade-offs Considered
- **Dependency container**: Considered but adds complexity; default parameters achieve similar goals with less infrastructure
- **Environment objects**: SwiftUI approach, but services need to work outside views
