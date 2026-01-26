# Testing

Testing Swift Concurrency code effectively.

## XCTest Async Support

### Basic async test

```swift
func testFetchUser() async throws {
    let user = try await userService.fetch(id: "123")
    XCTAssertEqual(user.name, "John")
}
```

### Async setup and teardown

```swift
override func setUp() async throws {
    try await super.setUp()
    await database.reset()
}

override func tearDown() async throws {
    await database.cleanup()
    try await super.tearDown()
}
```

## Swift Testing Framework

### Basic test

```swift
import Testing

@Test func fetchUser() async throws {
    let user = try await userService.fetch(id: "123")
    #expect(user.name == "John")
}
```

### Parameterized tests

```swift
@Test(arguments: ["id1", "id2", "id3"])
func fetchUser(id: String) async throws {
    let user = try await userService.fetch(id: id)
    #expect(user != nil)
}
```

### Test suites

```swift
@Suite struct UserServiceTests {
    let service = UserService()
    
    @Test func fetchReturnsUser() async throws {
        let user = try await service.fetch(id: "123")
        #expect(user != nil)
    }
    
    @Test func fetchInvalidIdThrows() async throws {
        await #expect(throws: UserError.notFound) {
            try await service.fetch(id: "invalid")
        }
    }
}
```

## Testing Actors

### Direct actor testing

```swift
@Test func actorState() async {
    let counter = Counter()
    
    await counter.increment()
    await counter.increment()
    
    let count = await counter.count
    #expect(count == 2)
}
```

### Testing concurrent access

```swift
@Test func concurrentIncrements() async {
    let counter = Counter()
    
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 {
            group.addTask { await counter.increment() }
        }
    }
    
    let count = await counter.count
    #expect(count == 100)
}
```

### Testing actor isolation

```swift
actor Store {
    private var items: [Item] = []
    
    func add(_ item: Item) { items.append(item) }
    func getAll() -> [Item] { items }
}

@Test func storeIsolation() async {
    let store = Store()
    
    // Concurrent adds
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<50 {
            group.addTask {
                await store.add(Item(id: i))
            }
        }
    }
    
    let items = await store.getAll()
    #expect(items.count == 50)
}
```

## Testing MainActor Code

### Using @MainActor in tests

```swift
@MainActor
@Test func viewModelUpdate() async {
    let viewModel = ContentViewModel()
    
    await viewModel.load()
    
    #expect(viewModel.items.count > 0)
}
```

### Running on MainActor explicitly

```swift
@Test func updateUI() async {
    await MainActor.run {
        let controller = ViewController()
        controller.updateLabel("Test")
        #expect(controller.label.text == "Test")
    }
}
```

## Testing Sendable

### Verify concurrent safety

```swift
@Test func sendableConcurrency() async {
    let cache = ThreadSafeCache()
    
    await withTaskGroup(of: Void.self) { group in
        // Concurrent writes
        for i in 0..<100 {
            group.addTask {
                cache.set("key\(i)", "value\(i)")
            }
        }
        // Concurrent reads
        for i in 0..<100 {
            group.addTask {
                _ = cache.get("key\(i)")
            }
        }
    }
    
    // No crash = thread safe
    #expect(true)
}
```

## Testing Task Cancellation

### Verify cancellation handling

```swift
@Test func taskCancellation() async throws {
    let task = Task {
        try await longRunningWork()
    }
    
    // Cancel after short delay
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    
    // Verify cancellation
    do {
        _ = try await task.value
        Issue.record("Expected cancellation error")
    } catch is CancellationError {
        // Expected
    }
}
```

### Test graceful cancellation

```swift
actor DownloadManager {
    func download(url: URL) async throws -> Data {
        var data = Data()
        
        for chunk in 0..<100 {
            try Task.checkCancellation()
            data.append(await fetchChunk(chunk))
        }
        
        return data
    }
}

@Test func downloadCancellation() async {
    let manager = DownloadManager()
    
    let task = Task {
        try await manager.download(url: testURL)
    }
    
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    
    do {
        _ = try await task.value
        Issue.record("Should have been cancelled")
    } catch is CancellationError {
        // Success
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
```

## Testing AsyncSequence

### Test stream values

```swift
@Test func asyncStreamValues() async {
    let stream = AsyncStream<Int> { continuation in
        continuation.yield(1)
        continuation.yield(2)
        continuation.yield(3)
        continuation.finish()
    }
    
    var values: [Int] = []
    for await value in stream {
        values.append(value)
    }
    
    #expect(values == [1, 2, 3])
}
```

### Test with timeout

```swift
@Test(.timeLimit(.seconds(5)))
func streamCompletes() async {
    let stream = makeStream()
    
    var count = 0
    for await _ in stream {
        count += 1
    }
    
    #expect(count > 0)
}
```

## Testing Error Handling

### Async throws

```swift
@Test func networkErrorHandling() async {
    let service = NetworkService(mockFailure: true)
    
    await #expect(throws: NetworkError.connectionFailed) {
        try await service.fetch()
    }
}
```

### Multiple error types

```swift
@Test func errorTypes() async {
    // Test specific error
    await #expect(throws: APIError.unauthorized) {
        try await api.protectedEndpoint()
    }
    
    // Test any error
    await #expect(throws: Error.self) {
        try await api.brokenEndpoint()
    }
}
```

## Mocking Async Dependencies

### Protocol-based mocking

```swift
protocol UserRepository {
    func fetch(id: String) async throws -> User
}

struct MockUserRepository: UserRepository {
    var mockUser: User?
    var mockError: Error?
    
    func fetch(id: String) async throws -> User {
        if let error = mockError { throw error }
        guard let user = mockUser else { throw TestError.noMock }
        return user
    }
}

@Test func serviceWithMock() async throws {
    var mock = MockUserRepository()
    mock.mockUser = User(id: "123", name: "Test")
    
    let service = UserService(repository: mock)
    let user = try await service.getUser(id: "123")
    
    #expect(user.name == "Test")
}
```

### Actor mocking

```swift
actor MockDatabase: DatabaseProtocol {
    var users: [User] = []
    var fetchDelay: Duration = .zero
    
    func fetch(id: String) async -> User? {
        if fetchDelay > .zero {
            try? await Task.sleep(for: fetchDelay)
        }
        return users.first { $0.id == id }
    }
}
```

## Testing Task Groups

### Verify concurrent execution

```swift
@Test func taskGroupConcurrency() async {
    let start = ContinuousClock().now
    
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    
    let duration = ContinuousClock().now - start
    
    // Should complete in ~100ms (concurrent), not ~1000ms (sequential)
    #expect(duration < .milliseconds(500))
}
```

### Test group result aggregation

```swift
@Test func taskGroupResults() async {
    let results = await withTaskGroup(of: Int.self) { group in
        for i in 1...5 {
            group.addTask { i * 2 }
        }
        
        return await group.reduce(into: []) { $0.append($1) }
    }
    
    #expect(results.sorted() == [2, 4, 6, 8, 10])
}
```

## Timing and Delays

### Test with controlled timing

```swift
@Test func debounce() async throws {
    let debouncer = Debouncer(delay: .milliseconds(100))
    var callCount = 0
    
    for _ in 0..<5 {
        await debouncer.submit {
            callCount += 1
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    
    // Wait for debounce
    try await Task.sleep(for: .milliseconds(150))
    
    #expect(callCount == 1) // Only last call executes
}
```

### Timeout expectations

```swift
@Test(.timeLimit(.seconds(2)))
func operationCompletesQuickly() async throws {
    let result = try await service.quickOperation()
    #expect(result != nil)
}
```

## Common Patterns

### Test helper for async assertions

```swift
func assertEventually(
    timeout: Duration = .seconds(1),
    condition: @escaping () async -> Bool
) async throws {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    
    while ContinuousClock().now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    
    Issue.record("Condition not met within timeout")
}

// Usage
@Test func eventuallyLoads() async throws {
    let viewModel = ViewModel()
    viewModel.startLoading()
    
    try await assertEventually {
        await viewModel.isLoaded
    }
}
```

### Race condition detection

```swift
@Test func noRaceConditions() async {
    let counter = Counter()
    
    // Run multiple times to catch races
    for _ in 0..<10 {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { await counter.increment() }
                group.addTask { _ = await counter.value }
            }
        }
    }
    
    // If we get here without crash, isolation works
    #expect(true)
}
```

## Best Practices

### 1. Always use async test methods

```swift
// ✅ Proper async test
@Test func asyncOperation() async throws {
    let result = try await operation()
    #expect(result != nil)
}

// ❌ Avoid: sync test with waiters
func testAsyncOperation() {
    let expectation = expectation(description: "")
    Task {
        _ = try await operation()
        expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)
}
```

### 2. Test cancellation paths

```swift
@Test func cancellationCleanup() async {
    var cleanupCalled = false
    
    let task = Task {
        defer { cleanupCalled = true }
        try await Task.sleep(for: .seconds(10))
    }
    
    task.cancel()
    _ = try? await task.value
    
    #expect(cleanupCalled)
}
```

### 3. Use appropriate timeouts

```swift
@Test(.timeLimit(.seconds(5)))
func networkOperation() async throws {
    // Has 5 second limit
}
```

### 4. Isolate tests properly

```swift
@Suite(.serialized)
struct DatabaseTests {
    // Tests run one at a time
}
```

### 5. Mock time-dependent code

```swift
protocol Clock {
    func sleep(for duration: Duration) async throws
}

struct RealClock: Clock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct MockClock: Clock {
    func sleep(for duration: Duration) async throws {
        // Instant, no actual wait
    }
}
```

## Summary

| Testing Need | Approach |
|--------------|----------|
| Async function | `async` test method |
| Actor state | `await` actor methods |
| MainActor code | `@MainActor` test |
| Cancellation | Cancel task, verify error |
| Concurrency | TaskGroup stress tests |
| Error handling | `#expect(throws:)` |
| Timing | `.timeLimit()` trait |

## Further Learning

For comprehensive testing strategies, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
