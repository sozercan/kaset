# Performance

Profiling and optimizing Swift Concurrency code.

## Key Performance Concepts

### Suspension overhead

Each `await` has potential overhead:

- Context saving
- Possible thread hop
- Context restoration

**Minimize awaits in tight loops.**

### Thread pool efficiency

Swift Concurrency uses a limited thread pool (typically CPU core count). Blocking any thread reduces pool efficiency.

**Never block threads with synchronous waits.**

### Actor contention

High-traffic actors become bottlenecks when many tasks await access.

**Design actors with minimal suspension and focused responsibilities.**

## Instruments Profiling

### Swift Concurrency instrument

Available in Xcode 13.2+. Shows:

- Task creation and lifecycle
- Actor access patterns
- Thread utilization
- Continuation execution

### How to profile

1. Product → Profile (⌘I)
2. Select "Swift Concurrency" template
3. Run your app
4. Analyze task timelines

### What to look for

- **Long task durations**: Possible blocking or inefficiency
- **Actor contention**: Many tasks waiting for same actor
- **Thread explosion**: Too many concurrent tasks
- **Gaps in execution**: Unnecessary suspension

## Common Performance Issues

### Issue 1: Unnecessary async

```swift
// ❌ Async but never awaits
func process() async -> Int {
    return 42 // No await needed
}

// ✅ Just make it sync
func process() -> Int {
    return 42
}
```

**Impact:** Async overhead with no benefit.

### Issue 2: Sequential awaits

```swift
// ❌ Sequential: 3 seconds total
let a = await fetchA() // 1 sec
let b = await fetchB() // 1 sec
let c = await fetchC() // 1 sec

// ✅ Concurrent: ~1 second total
async let a = fetchA()
async let b = fetchB()
async let c = fetchC()
let results = await (a, b, c)
```

**Impact:** Unnecessary wait time.

### Issue 3: Await in loops

```swift
// ❌ Sequential processing
for item in items {
    await process(item) // One at a time
}

// ✅ Concurrent processing
await withTaskGroup(of: Void.self) { group in
    for item in items {
        group.addTask {
            await process(item)
        }
    }
}
```

**Impact:** N times slower than necessary.

### Issue 4: Actor reentrancy checks

```swift
// ❌ Re-check after every suspension
actor Cache {
    var items: [Item] = []
    
    func loadAll() async {
        for i in 0..<100 {
            let item = await fetchItem(i) // Suspension
            items.append(item) // State may have changed
        }
    }
}

// ✅ Batch then update
actor Cache {
    var items: [Item] = []
    
    func loadAll() async {
        let newItems = await withTaskGroup(of: Item.self) { group in
            for i in 0..<100 {
                group.addTask { await fetchItem(i) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        items = newItems // Single state update
    }
}
```

**Impact:** Simpler state management, fewer race conditions.

### Issue 5: Blocking in async context

```swift
// ❌ Blocks thread
func loadData() async {
    let data = expensiveSyncComputation() // Blocks!
    process(data)
}

// ✅ Move to background if truly blocking
func loadData() async {
    let data = await Task.detached {
        expensiveSyncComputation()
    }.value
    process(data)
}
```

**Impact:** Starves thread pool.

## Task Group Optimization

### Limit concurrency

```swift
// ❌ 10,000 concurrent tasks
await withTaskGroup(of: Void.self) { group in
    for item in thousandsOfItems {
        group.addTask { await process(item) }
    }
}

// ✅ Bounded concurrency
await withTaskGroup(of: Void.self) { group in
    var pending = 0
    let maxConcurrency = 10
    
    for item in thousandsOfItems {
        if pending >= maxConcurrency {
            await group.next()
            pending -= 1
        }
        group.addTask { await process(item) }
        pending += 1
    }
}
```

### Process results as they complete

```swift
await withTaskGroup(of: Item.self) { group in
    for id in ids {
        group.addTask { await fetchItem(id) }
    }
    
    // Process as they complete, not waiting for all
    for await item in group {
        process(item)
    }
}
```

## Actor Performance

### Reduce suspension points

```swift
// ❌ Multiple suspension points
actor Store {
    func update() async {
        await step1()
        await step2() // Others can access between
        await step3()
    }
}

// ✅ Batch work before suspension
actor Store {
    func update() async {
        prepareSync()
        await networkCall()
        finalizeSync()
    }
}
```

### Consider nonisolated for read-only

```swift
actor Config {
    let defaults: [String: Any] // Immutable
    
    // ✅ No await needed for immutable data
    nonisolated var defaultTimeout: TimeInterval {
        (defaults["timeout"] as? TimeInterval) ?? 30
    }
}
```

### Split high-contention actors

```swift
// ❌ One actor for everything
actor AppState {
    var users: [User]
    var settings: Settings
    var cache: [String: Data]
}

// ✅ Separate concerns
actor UserStore { var users: [User] }
actor SettingsStore { var settings: Settings }
actor CacheStore { var cache: [String: Data] }
```

## Memory Performance

### Release references promptly

```swift
// ❌ Holds large data throughout
func process() async {
    let largeData = loadLargeData()
    await step1(largeData)
    await step2() // largeData still in memory
    await step3()
}

// ✅ Scope data tightly
func process() async {
    await processLargeData()
    await step2()
    await step3()
}

func processLargeData() async {
    let largeData = loadLargeData()
    await step1(largeData)
} // largeData released
```

### Avoid capturing in long-lived tasks

```swift
// ❌ Captures ViewModel for lifetime of task
Task { [viewModel] in
    await viewModel.longRunningWork()
}

// ✅ Use weak when appropriate
Task { [weak viewModel] in
    await viewModel?.longRunningWork()
}
```

## Reducing Await Overhead

### Batch operations

```swift
// ❌ Many small awaits
for item in items {
    await save(item)
}

// ✅ Single batch await
await saveAll(items)
```

### Cache results

```swift
actor ImageLoader {
    private var cache: [URL: Image] = [:]
    
    func load(_ url: URL) async -> Image {
        if let cached = cache[url] {
            return cached // No await needed
        }
        
        let image = await downloadImage(url)
        cache[url] = image
        return image
    }
}
```

### Use structured concurrency

```swift
// Automatic cancellation and cleanup
await withTaskGroup(of: Void.self) { group in
    // Child tasks managed efficiently
}
```

## Measurement

### Time async operations

```swift
func measure<T>(_ operation: () async throws -> T) async rethrows -> T {
    let start = ContinuousClock().now
    let result = try await operation()
    let duration = ContinuousClock().now - start
    print("Duration: \(duration)")
    return result
}

// Usage
let data = await measure {
    await fetchData()
}
```

### Profile with os_signpost

```swift
import os

let log = OSLog(subsystem: "com.app", category: "performance")

func fetchData() async -> Data {
    os_signpost(.begin, log: log, name: "fetchData")
    defer { os_signpost(.end, log: log, name: "fetchData") }
    
    return await network.fetch()
}
```

### Track task counts

```swift
actor TaskCounter {
    private var count = 0
    
    func increment() { count += 1; log() }
    func decrement() { count -= 1; log() }
    func log() { print("Active tasks: \(count)") }
}
```

## Performance Checklist

### Before shipping

- [ ] Profile with Swift Concurrency instrument
- [ ] Check for unnecessary async functions
- [ ] Verify concurrent operations use `async let` or TaskGroup
- [ ] Ensure no blocking calls in async contexts
- [ ] Review actor contention patterns
- [ ] Check task group concurrency limits
- [ ] Verify proper cancellation handling
- [ ] Measure key operation durations

### Anti-patterns to avoid

- [ ] Sequential awaits when concurrent possible
- [ ] Await in tight loops without TaskGroup
- [ ] Blocking synchronous calls in async functions
- [ ] Single high-traffic actor for unrelated state
- [ ] Creating thousands of unbounded tasks
- [ ] Holding large objects across suspension points

## Quick Wins

### 1. Parallel independent fetches

```swift
async let user = fetchUser()
async let posts = fetchPosts()
async let settings = fetchSettings()
return await Screen(user, posts, settings)
```

### 2. TaskGroup for collections

```swift
await withTaskGroup(of: Image.self) { group in
    for url in urls { group.addTask { await load(url) } }
    return await group.reduce(into: []) { $0.append($1) }
}
```

### 3. Nonisolated for immutable data

```swift
actor Cache {
    let maxSize: Int
    nonisolated var limit: Int { maxSize }
}
```

### 4. Batch state updates in actors

```swift
actor Store {
    func bulkUpdate(_ items: [Item]) {
        for item in items {
            data[item.id] = item
        }
        // One notification after all updates
        notifyObservers()
    }
}
```

## Summary

| Issue | Solution |
|-------|----------|
| Sequential awaits | `async let` or TaskGroup |
| Await in loops | TaskGroup |
| Actor contention | Split actors, reduce suspension |
| Thread blocking | Move to detached task |
| Memory pressure | Scope data, use weak references |
| Unbounded tasks | Limit concurrency in TaskGroup |

## Further Learning

For advanced profiling techniques and optimization strategies, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
