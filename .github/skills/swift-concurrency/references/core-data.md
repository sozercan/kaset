# Core Data

Integrating Core Data with Swift Concurrency safely.

## The Challenge

Core Data's `NSManagedObject` is not thread-safe:

- Objects tied to specific `NSManagedObjectContext`
- Contexts tied to specific queues
- Passing objects between threads crashes

Swift Concurrency moves work between threads automatically, creating potential conflicts.

## Core Principles

### 1. Use context's perform methods

```swift
await context.perform {
    // Safe Core Data work here
}
```

### 2. Never pass NSManagedObject across isolation

```swift
// ❌ Wrong: Passing object
func loadUser() async -> User? {
    await context.perform {
        fetchUser() // Returns NSManagedObject
    }
}

// ✅ Right: Pass value type
func loadUser() async -> UserDTO? {
    await context.perform {
        guard let user = fetchUser() else { return nil }
        return UserDTO(from: user) // Sendable value type
    }
}
```

### 3. Use background contexts for heavy work

```swift
let backgroundContext = container.newBackgroundContext()
await backgroundContext.perform {
    // Import, batch updates, etc.
}
```

## Sendable Value Types (DTOs)

### Create Sendable representations

```swift
struct UserDTO: Sendable {
    let id: UUID
    let name: String
    let email: String
    let createdAt: Date
}

extension UserDTO {
    init(from managedObject: User) {
        self.id = managedObject.id!
        self.name = managedObject.name ?? ""
        self.email = managedObject.email ?? ""
        self.createdAt = managedObject.createdAt ?? Date()
    }
}
```

### Convert before crossing boundaries

```swift
actor DataStore {
    let container: NSPersistentContainer
    
    func fetchUsers() async -> [UserDTO] {
        let context = container.viewContext
        
        return await context.perform {
            let request = User.fetchRequest()
            let users = (try? context.fetch(request)) ?? []
            return users.map { UserDTO(from: $0) }
        }
    }
}
```

## NSManagedObjectContext.perform

### Async version (iOS 15+, macOS 12+)

```swift
let result = await context.perform {
    // Work with context
    return someResult
}
```

### With scheduling

```swift
await context.perform(schedule: .immediate) {
    // Execute immediately on context's queue
}

await context.perform(schedule: .enqueued) {
    // Queue behind existing work
}
```

### Throwing version

```swift
do {
    try await context.perform {
        try context.save()
    }
} catch {
    handleError(error)
}
```

## Custom Executors for Core Data

### Why custom executors?

Ensure actor code runs on the correct queue for Core Data operations.

### Implementation

```swift
actor CoreDataActor {
    let context: NSManagedObjectContext
    let executor: SerialExecutor
    
    init(context: NSManagedObjectContext) {
        self.context = context
        // Create executor tied to context's queue
        self.executor = context.performExecutor
    }
    
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    
    func fetch() -> [UserDTO] {
        // Already on context's queue
        let request = User.fetchRequest()
        let users = (try? context.fetch(request)) ?? []
        return users.map { UserDTO(from: $0) }
    }
}
```

### Using DispatchSerialQueue

```swift
extension NSManagedObjectContext {
    var performExecutor: any SerialExecutor {
        // For main context
        if Thread.isMainThread {
            return MainActor.sharedUnownedExecutor
        }
        
        // For background contexts, create dedicated queue
        let queue = DispatchQueue(label: "CoreData.\(ObjectIdentifier(self))")
        return queue.asSerialExecutor()
    }
}
```

## Fetching Patterns

### Pattern 1: Fetch and convert

```swift
func fetchAllUsers() async -> [UserDTO] {
    await context.perform {
        let request = User.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "name", ascending: true)
        ]
        
        let users = (try? context.fetch(request)) ?? []
        return users.map { UserDTO(from: $0) }
    }
}
```

### Pattern 2: Fetch with predicate

```swift
func fetchUser(id: UUID) async -> UserDTO? {
    await context.perform {
        let request = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        
        guard let user = (try? context.fetch(request))?.first else {
            return nil
        }
        return UserDTO(from: user)
    }
}
```

### Pattern 3: Count without fetching

```swift
func countUsers() async -> Int {
    await context.perform {
        let request = User.fetchRequest()
        return (try? context.count(for: request)) ?? 0
    }
}
```

## Saving Patterns

### Pattern 1: Create and save

```swift
func createUser(name: String, email: String) async throws -> UserDTO {
    try await context.perform {
        let user = User(context: context)
        user.id = UUID()
        user.name = name
        user.email = email
        user.createdAt = Date()
        
        try context.save()
        return UserDTO(from: user)
    }
}
```

### Pattern 2: Update existing

```swift
func updateUser(id: UUID, name: String) async throws {
    try await context.perform {
        let request = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        guard let user = (try? context.fetch(request))?.first else {
            throw DataError.notFound
        }
        
        user.name = name
        try context.save()
    }
}
```

### Pattern 3: Delete

```swift
func deleteUser(id: UUID) async throws {
    try await context.perform {
        let request = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        guard let user = (try? context.fetch(request))?.first else {
            throw DataError.notFound
        }
        
        context.delete(user)
        try context.save()
    }
}
```

## Batch Operations

### Batch insert

```swift
func importUsers(_ dtos: [UserDTO]) async throws {
    let backgroundContext = container.newBackgroundContext()
    
    try await backgroundContext.perform {
        let batchInsert = NSBatchInsertRequest(
            entity: User.entity(),
            objects: dtos.map { dto in
                [
                    "id": dto.id,
                    "name": dto.name,
                    "email": dto.email,
                    "createdAt": dto.createdAt
                ]
            }
        )
        
        try backgroundContext.execute(batchInsert)
    }
    
    // Merge changes to view context
    await context.perform {
        context.refreshAllObjects()
    }
}
```

### Batch delete

```swift
func deleteAllUsers() async throws {
    try await context.perform {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "User")
        let batchDelete = NSBatchDeleteRequest(fetchRequest: request)
        batchDelete.resultType = .resultTypeObjectIDs
        
        let result = try context.execute(batchDelete) as? NSBatchDeleteResult
        let objectIDs = result?.result as? [NSManagedObjectID] ?? []
        
        // Merge to memory
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
            into: [context]
        )
    }
}
```

## SwiftUI Integration

### @FetchRequest with async loading

```swift
struct UserListView: View {
    @Environment(\.managedObjectContext) var context
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\.name)],
        animation: .default
    )
    private var users: FetchedResults<User>
    
    var body: some View {
        List(users) { user in
            Text(user.name ?? "")
        }
        .task {
            await refreshFromServer()
        }
    }
    
    func refreshFromServer() async {
        let newUsers = await api.fetchUsers()
        
        await context.perform {
            // Import new users
            for dto in newUsers {
                let user = User(context: context)
                user.id = dto.id
                user.name = dto.name
            }
            try? context.save()
        }
    }
}
```

### ViewModel pattern

```swift
@MainActor
class UserListViewModel: ObservableObject {
    @Published var users: [UserDTO] = []
    @Published var isLoading = false
    
    private let dataStore: DataStore
    
    func load() async {
        isLoading = true
        defer { isLoading = false }
        
        users = await dataStore.fetchAllUsers()
    }
}
```

## Common Pitfalls

### ❌ Accessing object outside context

```swift
let user = await context.perform {
    fetchUser()
}
print(user.name) // ❌ Crash: accessing outside perform
```

### ✅ Convert before returning

```swift
let dto = await context.perform {
    guard let user = fetchUser() else { return nil }
    return UserDTO(from: user)
}
print(dto?.name) // ✅ Safe: using value type
```

### ❌ Storing managed objects in actors

```swift
actor Store {
    var user: User? // ❌ Not Sendable, tied to context
}
```

### ✅ Store identifiers or DTOs

```swift
actor Store {
    var userId: UUID? // ✅ Sendable
    var userDTO: UserDTO? // ✅ Sendable
}
```

### ❌ Passing context to background tasks

```swift
Task.detached {
    await context.perform { } // ❌ Context may be deallocated
}
```

### ✅ Create new context for background

```swift
Task.detached { [container] in
    let backgroundContext = container.newBackgroundContext()
    await backgroundContext.perform { }
}
```

## Best Practices

### 1. Always use perform

```swift
// Every Core Data operation
await context.perform {
    // Safe zone
}
```

### 2. Use value types at boundaries

```swift
// DTOs cross isolation boundaries, not NSManagedObjects
struct BookDTO: Sendable { ... }
```

### 3. Create contexts appropriately

```swift
// View context for main thread UI
let viewContext = container.viewContext

// Background context for heavy work
let backgroundContext = container.newBackgroundContext()
```

### 4. Handle merge notifications

```swift
NotificationCenter.default.addObserver(
    forName: .NSManagedObjectContextDidSave,
    object: backgroundContext,
    queue: .main
) { notification in
    viewContext.mergeChanges(fromContextDidSave: notification)
}
```

### 5. Consider custom executors for actors

For actors that heavily use Core Data, align executor with context queue.

## Error Handling

```swift
func saveUser(_ dto: UserDTO) async throws {
    do {
        try await context.perform {
            let user = User(context: context)
            user.id = dto.id
            user.name = dto.name
            try context.save()
        }
    } catch {
        // Log error
        throw DataError.saveFailed(underlying: error)
    }
}
```

## Summary

| Pattern | Use Case |
|---------|----------|
| `context.perform` | All Core Data access |
| DTOs | Cross isolation boundaries |
| Background context | Heavy imports, batch ops |
| Custom executor | Actor-based data layers |
| `@FetchRequest` | SwiftUI live queries |

## Further Learning

For advanced patterns and performance optimization, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
