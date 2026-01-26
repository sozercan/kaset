# Glossary

Quick definitions of Swift Concurrency terms.

## Core Concepts

### async

Keyword marking a function that can suspend. Must be called with `await`.

```swift
func fetchData() async -> Data { ... }
```

### await

Keyword marking a potential suspension point. Required when calling `async` functions.

```swift
let data = await fetchData()
```

### Task

Unit of asynchronous work. Entry point for calling async code from sync context.

```swift
Task {
    await doAsyncWork()
}
```

### Actor

Reference type that isolates its mutable state. Only one task can access actor state at a time.

```swift
actor Counter {
    var count = 0
    func increment() { count += 1 }
}
```

### Sendable

Protocol marking types safe to share across concurrent contexts.

```swift
struct Point: Sendable {
    let x: Int
    let y: Int
}
```

## Isolation

### Actor isolation

The protection an actor provides for its mutable state. Access requires `await` from outside.

### MainActor

Global actor representing the main thread. Used for UI updates.

```swift
@MainActor
class ViewModel { ... }
```

### Global actor

An actor that can be applied to types and functions via attribute.

```swift
@globalActor
actor DatabaseActor {
    static let shared = DatabaseActor()
}
```

### nonisolated

Keyword to opt out of actor isolation for specific members.

```swift
actor Config {
    let id: UUID
    nonisolated var identifier: String { id.uuidString }
}
```

### Isolation domain

A region where code runs with specific isolation guarantees (e.g., MainActor, a specific actor).

## Task Concepts

### Structured concurrency

Tasks with clear parent-child relationships. Children cancelled when parent ends.

```swift
async let a = fetchA()
async let b = fetchB()
```

### Unstructured task

Task created without parent relationship. Lives independently.

```swift
Task { ... }          // Inherits priority/actor
Task.detached { ... } // Fully independent
```

### async let

Concurrent binding that starts work immediately and awaits on use.

```swift
async let image = loadImage()
// ... other work ...
let result = await image
```

### TaskGroup

Container for dynamic number of concurrent child tasks.

```swift
await withTaskGroup(of: Int.self) { group in
    group.addTask { await compute() }
}
```

### Task priority

Hint about task importance: `.high`, `.medium`, `.low`, `.userInitiated`, `.utility`, `.background`.

### Cancellation

Cooperative mechanism to stop tasks. Tasks must check `Task.isCancelled` or call `Task.checkCancellation()`.

## Continuations

### Continuation

Object that bridges callback-based code to async/await.

### withCheckedContinuation

Safe continuation that traps if resumed multiple times.

```swift
await withCheckedContinuation { continuation in
    legacyAPI { result in
        continuation.resume(returning: result)
    }
}
```

### withUnsafeContinuation

Faster continuation without runtime checks. Use carefully.

## Async Sequences

### AsyncSequence

Protocol for asynchronous iteration.

```swift
for await value in asyncSequence { ... }
```

### AsyncStream

Concrete type for creating async sequences from closures.

```swift
AsyncStream<Int> { continuation in
    continuation.yield(1)
    continuation.finish()
}
```

### AsyncThrowingStream

Async stream that can throw errors.

## Sendable Concepts

### @Sendable

Attribute for closures that cross isolation boundaries.

```swift
Task { @Sendable in
    // Must only capture Sendable values
}
```

### @unchecked Sendable

Conformance where you manually ensure thread safety.

```swift
final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    // ...
}
```

## Threading

### Cooperative thread pool

Swift's limited pool of threads (typically CPU core count) shared by all tasks.

### Suspension point

Location where task may pause (at `await`). Thread can do other work.

### Context switch

When CPU switches between tasks/threads. Swift Concurrency minimizes these.

### Executor

Object that runs async code. Determines where code executes.

## Swift 6 Terms

### Strict concurrency

Compiler mode that enforces data-race safety at compile time.

### Region-based isolation

Swift 6 feature tracking value ownership regions for better safety inference.

### @concurrent

Swift 6.2 attribute forcing function to run on background executor.

### nonisolated(nonsending)

Swift 6.2 feature preventing value sending while running on caller's isolation.

## Synchronization

### Data race

Undefined behavior when multiple threads access same memory with at least one write.

### Race condition

Logic bug where behavior depends on timing of concurrent operations.

### Mutex (SE-0433)

Swift 6 synchronization primitive for protecting shared state.

```swift
let counter = Mutex<Int>(0)
counter.withLock { $0 += 1 }
```

## Patterns

### Reentrancy

When other code runs on an actor during suspension, potentially seeing intermediate state.

### Priority inversion

When high-priority work waits for low-priority work. Actors avoid this.

### Thread explosion

Creating too many threads, causing memory and performance issues. Swift Concurrency prevents this.

### Backpressure

Flow control when producer is faster than consumer. Managed via AsyncStream buffering policies.

## Attributes Summary

| Attribute | Purpose |
|-----------|---------|
| `async` | Function can suspend |
| `await` | Marks suspension point |
| `@MainActor` | Runs on main thread |
| `@globalActor` | Custom global actor |
| `nonisolated` | Opts out of isolation |
| `@Sendable` | Safe closure for concurrency |
| `@unchecked Sendable` | Manual thread safety |
| `@concurrent` | Force background execution (6.2) |

## Quick Reference

### Making async call

```swift
let result = await asyncFunction()
```

### Error handling

```swift
do {
    let result = try await throwingAsync()
} catch {
    handle(error)
}
```

### Concurrent execution

```swift
async let a = taskA()
async let b = taskB()
let (resultA, resultB) = await (a, b)
```

### Actor access

```swift
let value = await actor.property
await actor.method()
```

### Creating task

```swift
Task { await work() }
Task.detached { await independentWork() }
```

### Cancellation check

```swift
try Task.checkCancellation()
if Task.isCancelled { return }
```

## Further Learning

For comprehensive explanations and examples, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
