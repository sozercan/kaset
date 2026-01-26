# Migration

Migrating existing code to Swift Concurrency and Swift 6.

## Migration Strategy

### Phased approach

**Phase 1: Enable warnings (Swift 5 mode)**

```swift
// Package.swift
.target(
    name: "MyTarget",
    swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
    ]
)
```

Or in Xcode: `SWIFT_STRICT_CONCURRENCY = complete`

**Phase 2: Fix warnings incrementally**

Address warnings one module at a time, starting with leaf dependencies.

**Phase 3: Enable Swift 6 mode**

```swift
// Package.swift
.swiftLanguageVersion(.v6)
```

Or in Xcode: `SWIFT_VERSION = 6`

### Module-by-module

1. Start with modules that have no dependencies
2. Work up the dependency chain
3. Fix each module completely before moving on
4. Test thoroughly at each step

## Common Migration Patterns

### GCD to async/await

**Before (GCD):**

```swift
func fetchUser(completion: @escaping (Result<User, Error>) -> Void) {
    DispatchQueue.global().async {
        do {
            let data = try loadData()
            let user = try parse(data)
            DispatchQueue.main.async {
                completion(.success(user))
            }
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }
}
```

**After (async/await):**

```swift
func fetchUser() async throws -> User {
    let data = try await loadData()
    return try parse(data)
}
```

### Completion handlers to async

**Before:**

```swift
func loadImage(url: URL, completion: @escaping (UIImage?) -> Void) {
    URLSession.shared.dataTask(with: url) { data, _, _ in
        let image = data.flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            completion(image)
        }
    }.resume()
}
```

**After:**

```swift
func loadImage(url: URL) async -> UIImage? {
    guard let (data, _) = try? await URLSession.shared.data(from: url) else {
        return nil
    }
    return UIImage(data: data)
}
```

### withCheckedContinuation for bridging

For APIs that can't be changed immediately:

```swift
func legacyFetch(completion: @escaping (Data?) -> Void) { ... }

func modernFetch() async -> Data? {
    await withCheckedContinuation { continuation in
        legacyFetch { data in
            continuation.resume(returning: data)
        }
    }
}
```

### withCheckedThrowingContinuation for throwing

```swift
func legacyFetch(completion: @escaping (Result<Data, Error>) -> Void) { ... }

func modernFetch() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        legacyFetch { result in
            continuation.resume(with: result)
        }
    }
}
```

## Sendable Conformance

### Value types

Usually automatic:

```swift
struct Config {
    let timeout: TimeInterval
    let retryCount: Int
}
// Implicitly Sendable
```

### Classes requiring @unchecked

```swift
// Before: Non-Sendable class
class Cache {
    private var data: [String: Data] = [:]
    private let lock = NSLock()
    
    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data[key]
    }
}

// After: Marked as unchecked Sendable
final class Cache: @unchecked Sendable {
    private var data: [String: Data] = [:]
    private let lock = NSLock()
    
    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data[key]
    }
}
```

### Converting to actors

```swift
// Before: Class with locks
class UserStore {
    private var users: [User] = []
    private let lock = NSLock()
    
    func add(_ user: User) {
        lock.lock()
        defer { lock.unlock() }
        users.append(user)
    }
}

// After: Actor
actor UserStore {
    private var users: [User] = []
    
    func add(_ user: User) {
        users.append(user)
    }
}
```

## MainActor Migration

### ViewModels

```swift
// Before
class ViewModel: ObservableObject {
    @Published var items: [Item] = []
    
    func load() {
        DispatchQueue.main.async {
            self.items = fetchedItems
        }
    }
}

// After
@MainActor
class ViewModel: ObservableObject {
    @Published var items: [Item] = []
    
    func load() async {
        items = await fetchItems()
    }
}
```

### UI updates

```swift
// Before
func updateUI() {
    DispatchQueue.main.async {
        self.label.text = "Updated"
    }
}

// After
@MainActor
func updateUI() {
    label.text = "Updated"
}

// Or from async context
func process() async {
    await MainActor.run {
        label.text = "Updated"
    }
}
```

## Notification observers

### Before (Combine/NotificationCenter)

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleNotification),
    name: .myNotification,
    object: nil
)
```

### After (AsyncSequence)

```swift
Task {
    for await _ in NotificationCenter.default.notifications(named: .myNotification) {
        handleNotification()
    }
}
```

## Protocol Migration

### Adding async to protocols

```swift
// Before
protocol DataLoader {
    func load(completion: @escaping (Data?) -> Void)
}

// After
protocol DataLoader {
    func load() async -> Data?
}
```

### Maintaining backward compatibility

```swift
protocol DataLoader {
    // New async requirement
    func load() async -> Data?
    
    // Legacy, deprecated
    @available(*, deprecated, message: "Use async version")
    func load(completion: @escaping (Data?) -> Void)
}

extension DataLoader {
    // Default implementation for legacy
    func load(completion: @escaping (Data?) -> Void) {
        Task {
            let data = await load()
            completion(data)
        }
    }
}
```

## Common Warning Fixes

### "Non-sendable type captured"

**Problem:**

```swift
class ViewModel {
    var data: [String] = []
}

let vm = ViewModel()
Task {
    vm.data.append("test") // Warning: Non-sendable captured
}
```

**Solutions:**

1. Make it MainActor:
```swift
@MainActor class ViewModel {
    var data: [String] = []
}
```

2. Make it Sendable:
```swift
final class ViewModel: Sendable {
    let data: [String] // Must be let for Sendable
}
```

3. Use actor:
```swift
actor ViewModel {
    var data: [String] = []
}
```

### "Actor-isolated property cannot be referenced"

**Problem:**

```swift
actor Store {
    var items: [Item] = []
}

let store = Store()
print(store.items) // Error
```

**Solution:**

```swift
print(await store.items)
```

### "Reference to captured var in concurrently-executing code"

**Problem:**

```swift
var count = 0
Task {
    count += 1 // Error
}
```

**Solutions:**

1. Capture as let:
```swift
let currentCount = count
Task {
    print(currentCount)
}
```

2. Use actor:
```swift
actor Counter {
    var count = 0
    func increment() { count += 1 }
}
```

## Testing Migration

### Update XCTest to async

```swift
// Before
func testFetch() {
    let expectation = expectation(description: "Fetch")
    
    service.fetch { result in
        XCTAssertNotNil(result)
        expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5)
}

// After
func testFetch() async throws {
    let result = try await service.fetch()
    XCTAssertNotNil(result)
}
```

## Swift 6 Specific Changes

### Default to complete concurrency checking

Swift 6 has strict concurrency by default.

### Region-based isolation

Swift 6 tracks value regions, reducing false positives:

```swift
// Works in Swift 6, may warn in Swift 5 strict mode
func process() async {
    var array = [1, 2, 3]
    
    await Task {
        array.append(4) // Swift 6 understands this is safe
    }.value
}
```

### nonisolated(nonsending)

New in Swift 6.2:

```swift
nonisolated(nonsending) func helper() async {
    // Runs on caller's isolation, doesn't send values
}
```

## Migration Checklist

### Preparation

- [ ] Enable strict concurrency warnings
- [ ] Review all GCD usage
- [ ] Identify Sendable requirements
- [ ] Plan module migration order

### Per-module

- [ ] Convert completion handlers to async
- [ ] Add Sendable conformance to types
- [ ] Mark classes with @MainActor where needed
- [ ] Convert singletons to actors where appropriate
- [ ] Update tests to async
- [ ] Fix all warnings

### Verification

- [ ] All tests pass
- [ ] No runtime crashes
- [ ] Performance acceptable
- [ ] Enable Swift 6 mode

## Incremental Adoption Tips

### 1. Start with leaf modules

Modules with no internal dependencies are easiest to migrate first.

### 2. Use async wrappers

Keep legacy APIs working while providing new async versions:

```swift
// Legacy
func oldAPI(completion: @escaping (Result) -> Void) { ... }

// Wrapper
func newAPI() async throws -> Result {
    try await withCheckedThrowingContinuation { cont in
        oldAPI { result in cont.resume(with: result) }
    }
}
```

### 3. @preconcurrency for third-party imports

Suppress warnings from non-updated libraries:

```swift
@preconcurrency import LegacyLibrary
```

### 4. Annotate incrementally

Add `@Sendable`, `@MainActor` as needed rather than all at once.

### 5. Test at each step

Run full test suite after each change.

## Summary

| Pattern | Migration Path |
|---------|----------------|
| Completion handlers | `async throws` + `withCheckedContinuation` |
| GCD queues | Actors + `@MainActor` |
| Locks | Actors or `@unchecked Sendable` |
| Mutable shared state | Actors |
| UI updates | `@MainActor` |
| Notification observers | `AsyncSequence` |

## Further Learning

For comprehensive migration strategies and examples, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
