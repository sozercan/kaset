# Async Sequences

Understanding AsyncSequence and AsyncStream for asynchronous iteration.

## What is AsyncSequence?

`AsyncSequence` is the async equivalent of `Sequence`. It produces values over time, awaiting each element.

```swift
for await value in someAsyncSequence {
    print(value)
}
```

### Key differences from Sequence

| Sequence | AsyncSequence |
|----------|---------------|
| `for value in sequence` | `for await value in asyncSequence` |
| Immediate iteration | Awaits each element |
| Finite or infinite | Often infinite (streams) |
| Synchronous | Asynchronous |

## Built-in AsyncSequences

### URL bytes

```swift
let url = URL(string: "https://example.com/data")!
for try await byte in url.resourceBytes {
    process(byte)
}
```

### URL lines

```swift
let url = URL(fileURLWithPath: "/path/to/file.txt")
for try await line in url.lines {
    print(line)
}
```

### NotificationCenter

```swift
let notifications = NotificationCenter.default.notifications(named: .myNotification)
for await notification in notifications {
    handle(notification)
}
```

### FileHandle bytes

```swift
let handle = FileHandle(forReadingAtPath: "/path/to/file")!
for try await byte in handle.bytes {
    process(byte)
}
```

## AsyncStream

### Creating custom async sequences

`AsyncStream` is the easiest way to create async sequences:

```swift
let stream = AsyncStream<Int> { continuation in
    for i in 1...5 {
        continuation.yield(i)
    }
    continuation.finish()
}

for await value in stream {
    print(value) // 1, 2, 3, 4, 5
}
```

### With external event source

```swift
func locationUpdates() -> AsyncStream<CLLocation> {
    AsyncStream { continuation in
        let manager = CLLocationManager()
        
        let delegate = LocationDelegate { location in
            continuation.yield(location)
        }
        
        manager.delegate = delegate
        manager.startUpdatingLocation()
        
        continuation.onTermination = { _ in
            manager.stopUpdatingLocation()
        }
    }
}
```

### Buffering policies

```swift
// Unlimited buffer (default)
AsyncStream<Int>(bufferingPolicy: .unbounded) { ... }

// Keep newest, drop old
AsyncStream<Int>(bufferingPolicy: .bufferingNewest(5)) { ... }

// Keep oldest, drop new
AsyncStream<Int>(bufferingPolicy: .bufferingOldest(5)) { ... }
```

## AsyncThrowingStream

For sequences that can throw errors:

```swift
let stream = AsyncThrowingStream<Data, Error> { continuation in
    do {
        let data = try fetchData()
        continuation.yield(data)
        continuation.finish()
    } catch {
        continuation.finish(throwing: error)
    }
}

do {
    for try await data in stream {
        process(data)
    }
} catch {
    handleError(error)
}
```

## Async Sequence Operators

### map

```swift
let doubled = numbers.map { $0 * 2 }
for await value in doubled {
    print(value)
}
```

### filter

```swift
let evens = numbers.filter { $0.isMultiple(of: 2) }
for await value in evens {
    print(value)
}
```

### compactMap

```swift
let parsed = strings.compactMap { Int($0) }
for await number in parsed {
    print(number)
}
```

### prefix

```swift
// Take first 5 elements
for await value in sequence.prefix(5) {
    print(value)
}
```

### dropFirst

```swift
// Skip first 3 elements
for await value in sequence.dropFirst(3) {
    print(value)
}
```

### first(where:)

```swift
if let found = await sequence.first(where: { $0 > 10 }) {
    print("Found: \(found)")
}
```

### reduce

```swift
let sum = await numbers.reduce(0, +)
print("Sum: \(sum)")
```

### contains

```swift
let hasNegative = await numbers.contains { $0 < 0 }
```

### Chaining operators

```swift
let result = await numbers
    .filter { $0 > 0 }
    .map { $0 * 2 }
    .prefix(10)
    .reduce(0, +)
```

## Creating Custom AsyncSequence

### Using AsyncStream (preferred)

```swift
struct Countdown: AsyncSequence {
    typealias Element = Int
    let start: Int
    
    func makeAsyncIterator() -> AsyncStream<Int>.Iterator {
        AsyncStream { continuation in
            for i in (0...start).reversed() {
                continuation.yield(i)
            }
            continuation.finish()
        }.makeAsyncIterator()
    }
}
```

### Manual implementation

```swift
struct Countdown: AsyncSequence {
    typealias Element = Int
    let start: Int
    
    struct AsyncIterator: AsyncIteratorProtocol {
        var current: Int
        
        mutating func next() async -> Int? {
            guard current >= 0 else { return nil }
            defer { current -= 1 }
            return current
        }
    }
    
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(current: start)
    }
}

for await value in Countdown(start: 5) {
    print(value) // 5, 4, 3, 2, 1, 0
}
```

## Cancellation

### Handling cancellation in AsyncStream

```swift
let stream = AsyncStream<Int> { continuation in
    let task = Task {
        for i in 0... {
            try Task.checkCancellation()
            continuation.yield(i)
            try await Task.sleep(for: .seconds(1))
        }
    }
    
    continuation.onTermination = { _ in
        task.cancel()
    }
}
```

### Breaking from async for loop

```swift
for await value in stream {
    if shouldStop(value) {
        break // Triggers onTermination
    }
    process(value)
}
```

## Common Patterns

### Pattern 1: Bridging callbacks to AsyncStream

```swift
class NetworkMonitor {
    func pathUpdates() -> AsyncStream<NWPath> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            
            monitor.start(queue: .main)
        }
    }
}
```

### Pattern 2: Timer stream

```swift
func timerStream(interval: Duration) -> AsyncStream<Date> {
    AsyncStream { continuation in
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(
            deadline: .now(),
            repeating: interval.timeInterval
        )
        timer.setEventHandler {
            continuation.yield(Date())
        }
        
        continuation.onTermination = { _ in
            timer.cancel()
        }
        
        timer.resume()
    }
}

// Usage
for await date in timerStream(interval: .seconds(1)) {
    print("Tick: \(date)")
}
```

### Pattern 3: Debounced search

```swift
func debouncedSearchResults(
    queries: AsyncStream<String>,
    delay: Duration
) -> AsyncStream<[SearchResult]> {
    AsyncStream { continuation in
        Task {
            var searchTask: Task<Void, Never>?
            
            for await query in queries {
                searchTask?.cancel()
                
                searchTask = Task {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    
                    let results = await search(query)
                    continuation.yield(results)
                }
            }
            
            continuation.finish()
        }
    }
}
```

### Pattern 4: Merge multiple streams

```swift
func merge<T>(
    _ streams: AsyncStream<T>...
) -> AsyncStream<T> {
    AsyncStream { continuation in
        Task {
            await withTaskGroup(of: Void.self) { group in
                for stream in streams {
                    group.addTask {
                        for await value in stream {
                            continuation.yield(value)
                        }
                    }
                }
            }
            continuation.finish()
        }
    }
}
```

## AsyncSequence vs Publisher

### Key differences

| AsyncSequence | Combine Publisher |
|---------------|-------------------|
| Pull-based | Push-based |
| Natural backpressure | Demand management |
| `for await` syntax | Subscription-based |
| Built into Swift | Framework import |
| Single consumer | Multiple subscribers |

### When to use which

**AsyncSequence:**
- Native Swift async code
- Single consumer
- Natural iteration patterns
- New Swift Concurrency code

**Combine Publisher:**
- Multiple subscribers needed
- Complex transformation pipelines
- Existing Combine infrastructure
- Reactive programming patterns

## Performance Considerations

### Buffering

Large unbounded buffers can consume memory:

```swift
// Be careful with unbounded
AsyncStream<Data>(bufferingPolicy: .unbounded) { ... }

// Consider bounded for high-volume streams
AsyncStream<Data>(bufferingPolicy: .bufferingNewest(100)) { ... }
```

### Avoid blocking in async sequences

```swift
// Bad: Blocking operation
for await value in stream {
    Thread.sleep(forTimeInterval: 1) // ❌ Blocks thread
}

// Good: Async operation
for await value in stream {
    try await Task.sleep(for: .seconds(1)) // ✅ Suspends
}
```

### Early termination

Use `prefix` or `break` to limit processing:

```swift
// Process only first 100
for await value in stream.prefix(100) {
    process(value)
}
```

## Best Practices

### 1. Always handle termination

```swift
continuation.onTermination = { termination in
    switch termination {
    case .finished:
        cleanup()
    case .cancelled:
        cancelExternalResource()
    @unknown default:
        break
    }
}
```

### 2. Use appropriate buffering

```swift
// High-frequency data: bounded buffer
AsyncStream(bufferingPolicy: .bufferingNewest(10)) { ... }

// Critical events: unbounded (careful with memory)
AsyncStream(bufferingPolicy: .unbounded) { ... }
```

### 3. Support cancellation

```swift
for await value in stream {
    if Task.isCancelled { break }
    await process(value)
}
```

### 4. Document stream characteristics

```swift
/// Emits location updates approximately every second.
/// - Note: Stream continues until cancelled or error.
/// - Important: Each value is the latest location.
func locationUpdates() -> AsyncStream<CLLocation>
```

### 5. Clean up resources

```swift
let stream = AsyncStream<Data> { continuation in
    let resource = openResource()
    
    // Yield values...
    
    continuation.onTermination = { _ in
        resource.close() // Always clean up
    }
}
```

## Summary

| Type | Use Case |
|------|----------|
| `AsyncSequence` | Protocol for async iteration |
| `AsyncStream` | Create from closures/callbacks |
| `AsyncThrowingStream` | Streams that can fail |
| Built-in sequences | URL bytes/lines, notifications |

## Further Learning

For advanced patterns and real-world examples, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
