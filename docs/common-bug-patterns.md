# Common Bug Patterns to Avoid

These patterns have caused bugs in this codebase. **Always check for these during code review.**

## ❌ Fire-and-Forget Tasks

```swift
// ❌ BAD: Task not tracked, errors lost, can't cancel
func likeTrack() {
    Task { await api.like(trackId) }
}

// ✅ GOOD: Track task, handle errors, support cancellation
private var likeTask: Task<Void, Error>?

func likeTrack() async throws {
    likeTask?.cancel()
    likeTask = Task {
        try await api.like(trackId)
    }
    try await likeTask?.value
}
```

## ❌ Optimistic Updates Without Proper Rollback

```swift
// ❌ BAD: CancellationError not handled, cache permanently wrong
func rate(_ song: Song, status: LikeStatus) async {
    let previous = cache[song.id]
    cache[song.id] = status  // Optimistic update
    do {
        try await api.rate(song.id, status)
    } catch {
        cache[song.id] = previous  // Doesn't run on cancellation!
    }
}

// ✅ GOOD: Handle ALL errors including cancellation
func rate(_ song: Song, status: LikeStatus) async {
    let previous = cache[song.id]
    cache[song.id] = status
    do {
        try await api.rate(song.id, status)
    } catch let error as CancellationError {
        cache[song.id] = previous  // Rollback on cancel
        throw error  // Propagate original cancellation
    } catch {
        cache[song.id] = previous  // Rollback on error
        throw error
    }
}
```

## ❌ Static Shared Singletons with Mutable Assignment

```swift
// ❌ BAD: Race condition if multiple instances created
class LibraryViewModel {
    static var shared: LibraryViewModel?
    init() { Self.shared = self }  // Overwrites previous!
}

// ✅ GOOD: Use SwiftUI Environment for dependency injection
@Observable @MainActor
class LibraryViewModel { /* ... */ }

// In parent view:
.environment(libraryViewModel)

// In child view:
@Environment(LibraryViewModel.self) var viewModel
```

## ❌ `.onAppear` Instead of `.task` for Async Work

```swift
// ❌ BAD: Task not cancelled on disappear, can update stale view
.onAppear {
    Task { await viewModel.load() }
}

// ✅ GOOD: Lifecycle-managed, auto-cancelled on disappear
.task {
    await viewModel.load()
}

// ✅ GOOD: With ID for re-execution on change
.task(id: playlistId) {
    await viewModel.load(playlistId)
}
```

## ❌ ForEach with Unstable Identity

```swift
// ❌ BAD: Index-based identity causes wrong views during mutations
ForEach(tracks.indices, id: \.self) { index in
    TrackRow(track: tracks[index])
}

// ❌ BAD: Array enumeration recreates identity on every change
ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
    TrackRow(track: track, rank: index + 1)
}

// ✅ GOOD: Use stable model identity
ForEach(tracks) { track in
    TrackRow(track: track)
}

// ✅ GOOD: If you need index for display (charts), use element ID
ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
    TrackRow(track: track, rank: index + 1)
}
```

## ❌ Background Tasks Not Cancelled on Deinit

```swift
// ❌ BAD: Task continues after ViewModel is deallocated
@Observable @MainActor
class HomeViewModel {
    private var backgroundTask: Task<Void, Never>?
    
    func startLoading() {
        backgroundTask = Task { /* ... */ }
    }
    // Missing deinit cleanup!
}

// ✅ GOOD: Cancel tasks in deinit
@Observable @MainActor
class HomeViewModel {
    private var backgroundTask: Task<Void, Never>?
    
    func startLoading() {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            // ...
        }
    }
    
    deinit {
        backgroundTask?.cancel()
    }
}
```

## ❌ Shared Continuation Tokens Across Different Requests

```swift
// ❌ BAD: Single token for all search types causes conflicts
class YTMusicClient {
    private var searchContinuationToken: String?  // Shared!
    
    func searchSongs() { /* sets token */ }
    func searchAlbums() { /* overwrites token! */ }
}

// ✅ GOOD: Scope tokens by request type or return in response
class YTMusicClient {
    private var continuationTokens: [String: String] = [:]
    
    func searchSongs() -> (songs: [Song], continuation: String?) {
        // Return token with response, let caller manage
    }
}
```

## ❌ Treating Generated IDs as Navigable API IDs

```swift
// ❌ BAD: Hash/UUID IDs pass this check but aren't real channel IDs
if !artist.id.isEmpty, !artist.id.contains("-") {
    navigateToArtist(artist)  // 400 error from API!
}

// ✅ GOOD: Check for the actual YouTube channel ID prefix
if artist.hasNavigableId {  // Checks id.hasPrefix("UC")
    navigateToArtist(artist)
}
```

Home page items often have subtitle runs with no `navigationEndpoint`, causing
`ParsingHelpers.extractArtists()` to generate SHA256 hash IDs. These hex strings
have no hyphens and pass naive `!contains("-")` checks, but fail when used as
API parameters. Always use `hasNavigableId` which validates the `UC` prefix for
artists (or `MPRE`/`OLAK` for albums, `MPSPP` for podcasts).
