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

## ❌ Guessing at Runtime Behavior Instead of Measuring

When a bug is about *timing, lifecycle, or "why didn't this run/load/update"*
(SwiftUI `.task`/state churn, cold-launch ordering, perceived latency),
**instrument and observe before changing code.** Reasoning about SwiftUI
lifecycle or async ordering from the source alone repeatedly produces wrong
fixes; a timestamped trace settles it in one launch.

**The app is sandboxed**, so most ad-hoc logging fails silently:

- `Logger`/`os_log` `.info`/`.debug` lines do **not** reliably appear in
  `log stream` / `log show`.
- A hardcoded `/tmp/...` file write is **blocked by the sandbox** and throws
  nothing — the file just never appears in the real `/tmp`.
- Window-screenshot automation (`screencapture` + AX bounds) is unreliable
  here too — prefer file traces over visual capture.

Use a throwaway file tracer in the app's **container** tmp
(`NSTemporaryDirectory()`), `synchronize()` after each line, and read it from
`~/Library/Containers/com.sertacozercan.Kaset/Data/tmp/`:

```swift
// TEMPORARY DIAGNOSTIC — remove before commit.
enum LoadTrace {
    nonisolated(unsafe) private static let path =
        NSTemporaryDirectory() + "kaset_trace.log"        // container tmp, NOT /tmp
    nonisolated(unsafe) private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    nonisolated(unsafe) private static let start = ProcessInfo.processInfo.systemUptime

    static func log(_ message: String) {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        if let d = String(format: "%8.1fms %@\n", ms, message).data(using: .utf8) {
            handle?.write(d)
            try? handle?.synchronize()   // flush so a crash/hang still leaves the line
        }
    }
}
```

Workflow: add traces at each phase boundary → rebuild (`Scripts/build-app.sh`)
→ launch fresh, bring frontmost so the view mounts → read the trace → fix what
the data points at → **re-measure to confirm** → delete the tracer. This is how
the ~840ms Home "rows-lag" was localized to 8 uncached topic-rail browses
publishing atomically after the slowest one (not to parsing or the grid fetch,
which were the intuitive-but-wrong guesses).

## ❌ Idle-Guarded Load That Deadlocks on `.task` Restart

SwiftUI restarts a view's `.task` during launch/layout churn — observed firing
**twice ~18 ms apart** on first paint. A load guarded by `loadingState == .idle`
plus a cancellation-resets-to-`.idle` catch creates a lost-update deadlock:

```swift
// ❌ BAD: restart cancels load #1; load #2 bails on the guard; #1's
// cancellation resets to .idle → stuck on the skeleton, nothing running.
func load() async {
    guard loadingState == .idle else { return }     // load #2 bails here
    loadingState = .loading
    do {
        let data = try await client.fetch()          // load #1 cancelled by restart
        // ...publish...
    } catch {
        if error is CancellationError { loadingState = .idle; return }  // → stuck
    }
}
```

Fix with a **single-flight** load: run the work in a stored *unstructured* `Task`
so it survives `.task` cancellation; concurrent callers coalesce onto it.

```swift
// ✅ GOOD: the work is decoupled from .task cancellation; restarts coalesce.
private var loadTask: Task<Void, Never>?

func load() async {
    if case .loaded = loadingState { return }   // a repeat after load is a no-op
    if let existing = loadTask { await existing.value; return }   // coalesce
    let task = Task { await performLoad() }
    loadTask = task
    await task.value
}

private func performLoad() async {
    defer { loadTask = nil }
    // ...do the load; set .loaded on success...
}

func refresh() async {            // explicit reload must cancel + restart
    loadTask?.cancel(); loadTask = nil
    loadingState = .idle
    await load()
}
```

Test the race directly: two concurrent `load()` calls with the first cancelled
must still end `.loaded` (not stuck `.idle`). And remember a cancelled *outer*
`.task` must NOT abort a persistent view-model load (the VM outlives the view in
the store) — only `refresh()` aborts. When a test encodes the old
"cancellation aborts the load" behavior, it was protecting the bug; rewrite it.

## Pre-Submit Checklists

### Performance

> See [architecture.md#performance-guidelines](architecture.md#performance-guidelines) for detailed patterns.

- [ ] No `await` calls inside loops or `ForEach`
- [ ] Lists use `LazyVStack`/`LazyHStack` for large datasets
- [ ] Network calls cancelled on view disappear (`.task` handles this)
- [ ] Parsers have `measure {}` tests if processing large payloads
- [ ] Images use `ImageCache` with appropriate `targetSize`
- [ ] Search input is debounced
- [ ] ForEach uses stable identity

### Concurrency Safety

- [ ] No fire-and-forget `Task { }` without error handling
- [ ] Optimistic updates handle `CancellationError` explicitly
- [ ] Background tasks cancelled in `deinit`
- [ ] Using `.task` instead of `.onAppear { Task { } }`
- [ ] Continuation tokens scoped per-request (not shared across types)
- [ ] No `static var shared` pattern with mutable assignment in `init`
- [ ] WebView message handlers removed in `dismantleNSView`
- [ ] `WKNavigationDelegate` implements `webViewWebContentProcessDidTerminate`
- [ ] View-model loads are single-flight (survive `.task` restart) — not idle-guarded in a way that deadlocks on cancellation
- [ ] Timing/lifecycle bugs were **measured** with a trace, not guessed; all diagnostic instrumentation removed before commit
