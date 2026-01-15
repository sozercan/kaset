# Sendable

Understanding the Sendable protocol for thread-safe data sharing.

## What is Sendable?

`Sendable` marks types as safe to share across concurrent contexts (isolation domains, threads).

```swift
struct Point: Sendable {
    let x: Int
    let y: Int
}
```

### Why it matters

Swift Concurrency prevents data races. The compiler uses `Sendable` to verify values crossing isolation boundaries are safe.

```swift
actor Store {
    func process(_ point: Point) { // Point must be Sendable
        // ...
    }
}
```

## Implicit Sendable Conformance

### Value types with Sendable members

```swift
// Implicitly Sendable
struct User {
    let id: UUID
    let name: String
    let age: Int
}
```

All properties are Sendable (`UUID`, `String`, `Int`), so `User` is implicitly Sendable.

### Enums with Sendable associated values

```swift
// Implicitly Sendable
enum Result {
    case success(Data)
    case failure(Error)
}
```

### Actors

All actors are implicitly Sendable:

```swift
actor DataStore { } // Automatically Sendable
```

### Tuples

Tuples of Sendable types are Sendable:

```swift
let pair: (Int, String) = (1, "hello") // Sendable
```

## Explicit Sendable

### Structs with non-obvious safety

```swift
struct Config: Sendable {
    let settings: [String: String]
}
```

Add conformance to signal intent, even if implicit.

### Classes (rare, requires care)

```swift
final class ImmutableCache: Sendable {
    let data: [String: String]
    
    init(data: [String: String]) {
        self.data = data
    }
}
```

**Requirements for class Sendable:**
- `final` class
- All properties immutable (`let`)
- All properties Sendable

## @unchecked Sendable

### When you know it's safe

```swift
final class ThreadSafeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    
    func get(_ key: String) -> Data? {
        lock.withLock { cache[key] }
    }
    
    func set(_ key: String, _ data: Data) {
        lock.withLock { cache[key] = data }
    }
}
```

**Use when:** You implement thread safety manually (locks, atomics).

**⚠️ Warning:** Compiler doesn't verify safety. Your responsibility.

### Common uses

- Legacy thread-safe types
- Bridging from Objective-C
- Performance-critical synchronized types
- Types using `OSAllocatedUnfairLock`, `NSLock`, `Mutex`

## Non-Sendable Types

### Reference types with mutable state

```swift
class MutableCounter { // Not Sendable
    var count = 0
}
```

**Problem:** Multiple tasks could mutate `count` simultaneously.

### Structs with non-Sendable properties

```swift
struct Container { // Not Sendable
    var counter: MutableCounter
}
```

### Solutions for non-Sendable

**1. Make it an actor:**

```swift
actor Counter {
    var count = 0
    func increment() { count += 1 }
}
```

**2. Use Sendable properties:**

```swift
struct Container: Sendable {
    let count: Int // Immutable, Sendable
}
```

**3. Keep within isolation:**

```swift
@MainActor
class ViewModel {
    var counter = MutableCounter() // Never leaves MainActor
}
```

## Sendable Closures

### @Sendable attribute

Closures that cross isolation need `@Sendable`:

```swift
func runInBackground(_ work: @Sendable () async -> Void) {
    Task {
        await work()
    }
}
```

### Implicit Sendable closures

`Task.init` requires Sendable closure:

```swift
Task {
    // This closure is implicitly @Sendable
    await doWork()
}
```

### Capturing in Sendable closures

```swift
var count = 0

Task {
    count += 1 // ❌ Error: Captured mutable variable
}
```

**Fix:** Capture immutable copy:

```swift
let currentCount = count

Task {
    print(currentCount) // ✅ Captured immutable value
}
```

## Sendable and Generics

### Generic constraints

```swift
struct Box<T: Sendable>: Sendable {
    let value: T
}
```

### Conditional conformance

```swift
struct Wrapper<T> {
    var value: T
}

extension Wrapper: Sendable where T: Sendable { }
```

## Region-Based Isolation (Swift 6)

### Sending values between regions

Swift 6 tracks regions for values:

```swift
// Swift 6 can understand this is safe
func process() async {
    var array = [1, 2, 3]
    
    await Task {
        array.append(4) // Safe: array moves to new region
    }.value
}
```

### Benefits

- Fewer false Sendable warnings
- More flexible value passing
- Compiler tracks ownership regions

## Common Sendable Patterns

### Pattern 1: Immutable struct

```swift
struct Configuration: Sendable {
    let apiURL: URL
    let timeout: TimeInterval
    let retryCount: Int
}
```

### Pattern 2: Enum with Sendable values

```swift
enum AppState: Sendable {
    case idle
    case loading
    case loaded([Item]) // Item must be Sendable
    case error(String)
}
```

### Pattern 3: Actor for mutable state

```swift
actor StateStore {
    private var state: AppState = .idle
    
    func update(_ newState: AppState) {
        state = newState
    }
    
    func current() -> AppState {
        state
    }
}
```

### Pattern 4: Sendable wrapper

```swift
struct UserSnapshot: Sendable {
    let id: UUID
    let name: String
    let email: String
}

// Create from non-Sendable source
extension UserSnapshot {
    init(from user: User) { // User might not be Sendable
        self.id = user.id
        self.name = user.name
        self.email = user.email
    }
}
```

## Sendable and Protocols

### Protocol inheritance

```swift
protocol DataProvider: Sendable {
    func fetch() async -> Data
}
```

Conforming types must also be Sendable.

### Existentials

`any Sendable` for heterogeneous collections:

```swift
func process(_ items: [any Sendable]) {
    // ...
}
```

## Debugging Sendable Issues

### Common errors

**"Type does not conform to Sendable"**

```swift
struct Container {
    var mutableClass: SomeClass // SomeClass not Sendable
}
```

**"Capture of mutable variable in Sendable closure"**

```swift
var x = 0
Task { x += 1 } // ❌
```

### Solutions checklist

1. Make all properties Sendable
2. Use `let` instead of `var` for class properties
3. Mark class as `final`
4. Use `@unchecked Sendable` with manual synchronization
5. Keep non-Sendable types within isolation boundary
6. Create Sendable snapshots for crossing boundaries

## Sendable Best Practices

### 1. Prefer value types

```swift
// Good: Naturally Sendable
struct User: Sendable {
    let id: UUID
    let name: String
}

// Avoid: Requires more care
class User: Sendable { ... }
```

### 2. Design for immutability

```swift
struct State: Sendable {
    let items: [Item]
    let selectedIndex: Int
    
    func selecting(_ index: Int) -> State {
        State(items: items, selectedIndex: index)
    }
}
```

### 3. Use actors for mutable reference types

```swift
actor ItemStore {
    private var items: [Item] = []
    
    func add(_ item: Item) {
        items.append(item)
    }
}
```

### 4. Document @unchecked usage

```swift
/// Thread-safe cache using NSLock.
/// All access is synchronized through lock.
final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    // ...
}
```

### 5. Create snapshots for sharing

```swift
actor DataManager {
    private var data: MutableData
    
    func snapshot() -> DataSnapshot {
        DataSnapshot(from: data) // Sendable snapshot
    }
}
```

### 6. Keep isolation boundaries clean

```swift
@MainActor
class ViewModel {
    // Non-Sendable is OK, stays on MainActor
    var mutableState = MutableState()
}
```

## Summary

| Type | Sendable Status |
|------|----------------|
| Value types with Sendable properties | Implicit ✅ |
| Enums with Sendable associated values | Implicit ✅ |
| Actors | Always ✅ |
| Final classes with immutable Sendable properties | Explicit ✅ |
| Mutable classes | ❌ (use actor) |
| Manually synchronized classes | `@unchecked Sendable` |

## Further Learning

For advanced patterns and migration strategies, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
