# Actors

Understanding actors for safe concurrent state management.

## What is an Actor?

An actor is a reference type that protects its mutable state with **isolation**. Only one task can access actor state at a time.

```swift
actor Counter {
    private var count = 0
    
    func increment() {
        count += 1
    }
    
    func getCount() -> Int {
        count
    }
}
```

### Key properties

- **Reference type** (like class)
- **Isolated state**: Only accessible from inside actor
- **Serial access**: One task at a time
- **Thread-safe**: No data races

## Actor Isolation

### Inside the actor

Code inside actor can access state directly:

```swift
actor Store {
    var items: [Item] = []
    
    func add(_ item: Item) {
        items.append(item) // Direct access
    }
    
    func count() -> Int {
        items.count // Direct access
    }
}
```

### Outside the actor

External access requires `await`:

```swift
let store = Store()
await store.add(Item())
let count = await store.count()
```

**Why await?** Caller might need to wait for actor to be available.

## MainActor

### What is @MainActor?

A global actor representing the main thread. Essential for UI work.

```swift
@MainActor
class ViewModel: ObservableObject {
    @Published var items: [String] = []
    
    func load() async {
        items = await fetchItems()
    }
}
```

### Marking functions

```swift
@MainActor
func updateUI() {
    label.text = "Updated"
}
```

### Isolation inheritance

Child types inherit isolation:

```swift
@MainActor
class ParentVM {
    func update() { } // MainActor
}

class ChildVM: ParentVM {
    func refresh() { } // Also MainActor
}
```

### Explicit main actor calls

```swift
func processData() async {
    let result = await compute()
    
    await MainActor.run {
        self.label.text = result
    }
}
```

## Global Actors

### Creating custom global actors

```swift
@globalActor
actor DatabaseActor {
    static let shared = DatabaseActor()
}

@DatabaseActor
class DatabaseManager {
    func query() -> [Row] { ... }
}
```

### When to use

- Consistent isolation for related types
- Shared resource management
- Background processing domains

## Nonisolated

### Breaking out of isolation

Mark functions/properties that don't need actor isolation:

```swift
actor Store {
    let id: UUID // Immutable
    private var items: [Item] = []
    
    nonisolated var identifier: String {
        id.uuidString // No await needed
    }
    
    func add(_ item: Item) {
        items.append(item)
    }
}

let id = store.identifier // No await!
```

### Protocol conformance

Common for `Hashable`, `Equatable`:

```swift
actor User: Hashable {
    let id: UUID
    
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    nonisolated static func == (lhs: User, rhs: User) -> Bool {
        lhs.id == rhs.id
    }
}
```

### nonisolated(unsafe)

Escape hatch for immutable state accessed without isolation:

```swift
actor Config {
    nonisolated(unsafe) var debugMode = false // ⚠️ Use carefully
}
```

## Actor Reentrancy

### The problem

Actors allow other tasks to run during suspension:

```swift
actor Account {
    var balance: Int = 100
    
    func withdraw(_ amount: Int) async -> Bool {
        guard balance >= amount else { return false }
        
        await logTransaction() // Suspension point!
        
        balance -= amount // ⚠️ Balance may have changed!
        return true
    }
}
```

Two concurrent withdrawals of 60 from 100 balance:
1. Task 1: Checks balance (100 >= 60 ✓)
2. Task 1: Suspends at log
3. Task 2: Checks balance (100 >= 60 ✓)
4. Task 2: Suspends at log
5. Both succeed → balance becomes -20!

### Solutions

**1. Complete state changes before suspension:**

```swift
func withdraw(_ amount: Int) async -> Bool {
    guard balance >= amount else { return false }
    balance -= amount // State change BEFORE await
    await logTransaction()
    return true
}
```

**2. Re-check after suspension:**

```swift
func withdraw(_ amount: Int) async -> Bool {
    guard balance >= amount else { return false }
    await logTransaction()
    
    // Re-check condition
    guard balance >= amount else { return false }
    balance -= amount
    return true
}
```

**3. Use synchronous helpers:**

```swift
func withdraw(_ amount: Int) async -> Bool {
    let success = tryWithdraw(amount)
    if success {
        await logTransaction()
    }
    return success
}

private func tryWithdraw(_ amount: Int) -> Bool {
    guard balance >= amount else { return false }
    balance -= amount
    return true
}
```

## Sendable with Actors

### Actors are Sendable

Actors can be passed across isolation boundaries:

```swift
actor Store { }

func process(_ store: Store) async {
    await store.doWork()
}
```

### State must be Sendable (for crossing boundaries)

```swift
actor Cache {
    func get() -> Item { ... } // Item must be Sendable
}
```

Non-Sendable types can stay inside actor but can't leave.

## Custom Executors

### What are executors?

Executors determine where actor code runs. Default uses cooperative pool.

### Using SerialExecutor

```swift
actor MyActor {
    let executor = DispatchSerialQueue(label: "my.queue")
    
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
}
```

### When to use

- Integration with existing GCD code
- Specific threading requirements
- Core Data contexts

## Actor Best Practices

### 1. Keep actors focused

```swift
// Good: Single responsibility
actor UserStore {
    private var users: [User] = []
    func add(_ user: User) { }
    func find(_ id: UUID) -> User? { }
}

// Avoid: Too many responsibilities
actor AppState {
    var users: [User] = []
    var settings: Settings = .default
    var cache: [String: Data] = [:]
    // ...
}
```

### 2. Minimize suspension points

```swift
// Good: Sync state changes, then suspend
func update(_ item: Item) async {
    items[item.id] = item
    await persistToDisk()
}

// Risky: State change after suspension
func update(_ item: Item) async {
    await validateOnServer()
    items[item.id] = item // ⚠️ Reentrancy issue
}
```

### 3. Prefer immutable boundaries

```swift
struct ItemSnapshot: Sendable {
    let id: UUID
    let name: String
}

actor ItemStore {
    private var items: [UUID: Item] = [:]
    
    func snapshot(_ id: UUID) -> ItemSnapshot? {
        guard let item = items[id] else { return nil }
        return ItemSnapshot(id: item.id, name: item.name)
    }
}
```

### 4. Use nonisolated for constants

```swift
actor Service {
    let baseURL: URL
    private var cache: [String: Data] = [:]
    
    nonisolated var host: String {
        baseURL.host ?? ""
    }
}
```

### 5. Consider actor granularity

```swift
// Fine-grained: Each user has own actor
actor User {
    var name: String
    var settings: Settings
}

// Coarse-grained: Single store for all users
actor UserStore {
    var users: [UUID: User]
}
```

Fine-grained = more concurrency, more overhead
Coarse-grained = less concurrency, simpler management

## MainActor Best Practices

### Mark ViewModels

```swift
@MainActor
class ContentViewModel: ObservableObject {
    @Published var items: [Item] = []
    
    func refresh() async {
        items = await service.fetch()
    }
}
```

### UI updates always on MainActor

```swift
// In non-MainActor context
func process() async {
    let result = await compute()
    
    await MainActor.run {
        updateUI(with: result)
    }
}
```

### Avoid sprinkling @MainActor

```swift
// Avoid: Random MainActor methods
class Service {
    func fetch() async { }
    
    @MainActor
    func updateCache() { } // Why here?
}

// Better: Consistent isolation
@MainActor
class ViewModel {
    func updateCache() { }
}
```

## Swift 6 Mutex (SE-0433)

### New synchronization primitive

For protecting state without full actor overhead:

```swift
import Synchronization

final class Counter: Sendable {
    let value = Mutex<Int>(0)
    
    func increment() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }
}
```

### When to use Mutex vs Actor

**Use Mutex when:**
- Simple synchronization needed
- No suspension points required
- Performance critical sections

**Use Actor when:**
- Complex state management
- Need async operations inside
- Multiple related state pieces

### Comparison

```swift
// Actor: Can await inside
actor Store {
    var items: [Item] = []
    
    func refresh() async {
        items = await fetch() // OK
    }
}

// Mutex: Synchronous only
final class Store: Sendable {
    let items = Mutex<[Item]>([])
    
    func add(_ item: Item) {
        items.withLock { $0.append(item) }
    }
    
    // Can't await inside withLock!
}
```

## Common Patterns

### Actor as cache

```swift
actor ImageCache {
    private var cache: [URL: Image] = [:]
    
    func image(for url: URL) async -> Image {
        if let cached = cache[url] {
            return cached
        }
        
        let image = await downloadImage(url)
        cache[url] = image
        return image
    }
}
```

### Actor as coordinator

```swift
actor TaskCoordinator {
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    
    func start(_ work: @Sendable @escaping () async -> Void) -> UUID {
        let id = UUID()
        activeTasks[id] = Task {
            await work()
            await self.complete(id)
        }
        return id
    }
    
    func cancel(_ id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
    }
    
    private func complete(_ id: UUID) {
        activeTasks[id] = nil
    }
}
```

## Summary

| Concept | Use Case |
|---------|----------|
| `actor` | Protect mutable state, async operations |
| `@MainActor` | UI updates, ViewModels |
| `@globalActor` | Domain-specific isolation |
| `nonisolated` | Escape isolation for immutable data |
| `Mutex` | Simple sync, no suspension needed |

## Further Learning

For advanced patterns and real-world actor usage, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
