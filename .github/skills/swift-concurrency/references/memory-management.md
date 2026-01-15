# Memory Management

Understanding memory and ownership patterns specific to Swift Concurrency.

## Key Concepts

### Reference Counting in Tasks

Tasks maintain strong references to captured values. Closures passed to `Task.init` or `Task.detached` capture variables just like other closures.

```swift
class ViewModel {
    func start() {
        Task {
            // 'self' captured strongly
            await loadData()
        }
    }
    
    func loadData() async { ... }
}
```

### Why is this different?

Tasks have **indefinite lifetimes**. Unlike completion handlers tied to scope, a Task lives until it finishes or is cancelled.

**Problem**: Strong captures can extend object lifetimes unexpectedly.

## Retain Cycles in Tasks

### Classic pattern (no cycle)

```swift
class ViewModel {
    func start() {
        Task {
            await self.loadData() // Strong reference
        }
    }
}
```

**No cycle because**: Task doesn't create circular reference. Task holds → ViewModel, but ViewModel doesn't hold → Task.

### When cycles occur

```swift
class ViewModel {
    var task: Task<Void, Never>?
    
    func start() {
        task = Task {
            await self.loadData() // ⚠️ Cycle!
        }
    }
}
// ViewModel → task → closure → ViewModel
```

**Solution**: Break cycle with `[weak self]` or nil out task:

```swift
class ViewModel {
    var task: Task<Void, Never>?
    
    func start() {
        task = Task { [weak self] in
            await self?.loadData()
        }
    }
    
    // Or cancel in deinit
    deinit {
        task?.cancel()
        task = nil
    }
}
```

## Weak Self Patterns

### When to use `[weak self]`

**Use when**: Class stores reference to the task, or task outlives the class.

```swift
// Good: Task stored
class ViewModel {
    private var downloadTask: Task<Void, Never>?
    
    func startDownload() {
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.download()
        }
    }
}
```

**Skip when**: Task is fire-and-forget, not stored.

```swift
// OK: Task not stored
class ViewModel {
    func doSomething() {
        Task {
            await self.work() // No cycle risk
        }
    }
}
```

### Implicit self capture (Swift 5.8+)

SwiftUI's `.task` modifier handles capture safely:

```swift
struct MyView: View {
    @StateObject var vm = ViewModel()
    
    var body: some View {
        Text("Hello")
            .task {
                await vm.load() // Safe, tied to view lifecycle
            }
    }
}
```

### Actor self capture

Actors are **reference types**. Same rules apply:

```swift
actor DataStore {
    var loadTask: Task<Void, Never>?
    
    func startLoad() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
    }
}
```

## Sendable and Value Copying

### Value types are copied

When values cross isolation boundaries:

```swift
struct Data: Sendable {
    var items: [Int]
}

actor Store {
    func process(_ data: Data) {
        // 'data' is a copy, safe to mutate
    }
}
```

**No memory issues**: Each isolation domain has its own copy.

### Reference types require care

```swift
class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Any] = [:]
    
    func set(_ key: String, _ value: Any) {
        lock.withLock {
            items[key] = value
        }
    }
}
```

**Memory safety** relies on your synchronization.

## Common Memory Issues

### Issue 1: Long-running tasks holding references

```swift
class ImageLoader {
    func loadImages() async {
        for url in urls {
            await downloadImage(url) // Hours for large set
        }
    }
}

// If user navigates away, ImageLoader stays in memory
```

**Fix**: Check cancellation and allow early exit:

```swift
func loadImages() async throws {
    for url in urls {
        try Task.checkCancellation()
        await downloadImage(url)
    }
}
```

### Issue 2: Capturing large objects

```swift
Task {
    let hugeData = loadLargeDataset()
    await process(hugeData) // hugeData held until task completes
    await moreWork() // hugeData still in memory
}
```

**Fix**: Scope data tightly:

```swift
Task {
    await processLargeData()
    await moreWork()
}

func processLargeData() async {
    let hugeData = loadLargeDataset()
    await process(hugeData)
} // hugeData released here
```

### Issue 3: Unstructured tasks accumulating

```swift
for item in items {
    Task {
        await process(item) // 1000 concurrent tasks
    }
}
```

**Problems**: Memory pressure, too many suspended tasks.

**Fix**: Use `TaskGroup` for bounded concurrency:

```swift
await withTaskGroup(of: Void.self) { group in
    for item in items {
        group.addTask {
            await process(item)
        }
    }
}
```

## Task Hierarchy and Memory

### Structured tasks

Child tasks automatically cancelled when parent ends:

```swift
func loadContent() async {
    async let images = loadImages()
    async let text = loadText()
    
    // If loadContent cancelled, both child tasks cancelled
    return await (images, text)
}
```

**Memory benefit**: Resources freed together, no orphaned work.

### Unstructured tasks

`Task { }` creates independent lifetime:

```swift
@MainActor
class Controller {
    func start() {
        Task {
            // Lives beyond 'start()' scope
            await longRunningWork()
        }
    }
}
```

**Memory consideration**: Task lives until completion. Store and cancel if needed.

## Actor Isolation and Memory

### Actor state ownership

Actors own their mutable state. No external references allowed:

```swift
actor Store {
    private var cache: [String: Data] = [:] // Actor-owned
    
    func get(_ key: String) -> Data? {
        cache[key]
    }
}
```

**Memory is isolated**: No data races, no shared mutable state issues.

### Crossing isolation boundaries

Sending values out of actor:

```swift
actor Store {
    private var items: [Item] = []
    
    func getItems() -> [Item] {
        items // Copy if Sendable, else compile error
    }
}
```

**Non-Sendable types** can't leave actor without unsafe escape hatch.

## Best Practices

### 1. Prefer structured concurrency

```swift
// Good: Automatic cleanup
await withTaskGroup(of: Void.self) { group in
    group.addTask { await work1() }
    group.addTask { await work2() }
}

// Avoid: Manual tracking
let task1 = Task { await work1() }
let task2 = Task { await work2() }
// Must manually manage lifetime
```

### 2. Cancel tasks in deinit

```swift
class ViewModel {
    private var task: Task<Void, Never>?
    
    deinit {
        task?.cancel()
    }
}
```

### 3. Use weak self when storing tasks

```swift
task = Task { [weak self] in
    guard let self else { return }
    await self.work()
}
```

### 4. Scope captured values tightly

```swift
// Avoid
Task {
    let bigThing = createBigThing()
    await step1(bigThing)
    await step2() // bigThing still held
    await step3()
}

// Better
Task {
    await useBigThing()
    await step2()
    await step3()
}
```

### 5. Respond to cancellation

```swift
func work() async throws {
    for item in items {
        try Task.checkCancellation()
        await process(item)
    }
}
```

### 6. Profile with Instruments

Use **Allocations** and **Leaks** instruments to:
- Track object lifetimes
- Find retain cycles
- Monitor memory pressure

## Memory Debugging

### Finding leaks

1. Run with Leaks instrument
2. Look for growing allocations
3. Check `Task` and captured closure references

### Common symptoms

- Memory grows over time
- `deinit` not called
- Tasks running after view dismissed

### Diagnosis steps

1. Add `print` in `deinit`
2. Check if Task is stored
3. Look for `[weak self]` opportunities
4. Verify cancellation handling

## Summary

| Pattern | Memory Impact | Solution |
|---------|--------------|----------|
| Stored task with strong self | Retain cycle | `[weak self]` or cancel in deinit |
| Fire-and-forget task | OK if short-lived | Consider structured alternative |
| Long-running task | Holds references | Check cancellation, scope captures |
| Unstructured task flood | Memory pressure | Use TaskGroup |
| Actor state | Safe, isolated | No special handling |

## Further Learning

For advanced patterns and real-world debugging, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
