# Linting

SwiftLint rules for Swift Concurrency and static analysis best practices.

## Essential SwiftLint Rules

### async_without_await

Detects async functions that never await:

```yaml
# .swiftlint.yml
async_without_await:
  severity: warning
```

**Problem:**

```swift
func loadData() async -> Data {
    return Data() // Never awaits anything
}
```

**Why it matters:** Unnecessary async adds overhead. Either await something or remove async.

**Fix:**

```swift
func loadData() -> Data {
    return Data()
}
```

Or if it should be async:

```swift
func loadData() async -> Data {
    let data = await fetchFromNetwork()
    return data
}
```

### no_async_in_sync_context

Prevents calling async code incorrectly:

```yaml
no_async_in_sync_context:
  severity: error
```

**Problem:**

```swift
func syncFunction() {
    Task {
        await asyncWork() // Fire and forget
    }
}
```

**Why it matters:** Task errors are silently ignored, lifecycle is unmanaged.

### weak_delegate

Ensures delegates are weak:

```yaml
weak_delegate:
  severity: warning
```

Relevant to concurrency because strong delegates with async operations can cause retain cycles.

## Custom Rules

### Detect Thread.sleep misuse

```yaml
custom_rules:
  thread_sleep_in_async:
    name: "Thread.sleep in async context"
    regex: 'Thread\.sleep'
    message: "Use Task.sleep(for:) instead of Thread.sleep in async contexts"
    severity: warning
```

### Detect DispatchQueue in async

```yaml
custom_rules:
  dispatch_queue_in_async:
    name: "DispatchQueue in async context"
    regex: 'DispatchQueue\.(main|global)'
    message: "Consider using actors or @MainActor instead of DispatchQueue in Swift Concurrency"
    severity: warning
```

### Force unwrap prevention

```yaml
force_unwrapping:
  severity: error
```

Important in async code where nil states can occur unexpectedly.

## Recommended Configuration

```yaml
# .swiftlint.yml for Swift Concurrency projects

opt_in_rules:
  - async_without_await
  - weak_delegate
  - empty_count
  - first_where
  - sorted_first_last
  - contains_over_filter_count
  - contains_over_filter_is_empty
  - contains_over_first_not_nil
  - flatmap_over_map_reduce
  - last_where
  - reduce_boolean
  - reduce_into

disabled_rules:
  - todo  # Allow TODO comments during development

# Rule configurations
nesting:
  type_level: 2

identifier_name:
  min_length: 2
  excluded:
    - id
    - x
    - y
    - i

line_length:
  warning: 120
  error: 200
  ignores_urls: true
  ignores_function_declarations: true

function_body_length:
  warning: 50
  error: 100

type_body_length:
  warning: 300
  error: 500

file_length:
  warning: 500
  error: 1000

custom_rules:
  thread_sleep_usage:
    name: "Thread.sleep usage"
    regex: 'Thread\.sleep'
    message: "Use Task.sleep(for:) instead of Thread.sleep"
    severity: warning

  dispatch_queue_async:
    name: "DispatchQueue.async usage"
    regex: 'DispatchQueue.*\.async'
    message: "Consider using Task {} or actors instead of DispatchQueue.async"
    severity: warning

  print_statement:
    name: "Print statement"
    regex: '\bprint\s*\('
    message: "Use proper logging instead of print statements"
    severity: warning
    excluded: ".*Tests.*"
```

## Xcode Build Settings

### Enable strict concurrency checking

In Build Settings:

```
SWIFT_STRICT_CONCURRENCY = complete
```

Or in `Package.swift`:

```swift
.target(
    name: "MyTarget",
    swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
    ]
)
```

### Swift 6 language mode

```
SWIFT_VERSION = 6
```

Or in `Package.swift`:

```swift
.target(
    name: "MyTarget",
    swiftSettings: [
        .swiftLanguageMode(.v6)
    ]
)
```

## Compiler Warnings to Watch

### "Non-sendable type"

```
Non-sendable type 'MyClass' in asynchronous access
```

**Fix:** Make type Sendable or use actor isolation.

### "Actor-isolated property"

```
Actor-isolated property 'x' can not be referenced from a non-isolated context
```

**Fix:** Use `await` or mark caller as isolated to same actor.

### "Capture of non-sendable"

```
Capture of 'self' with non-sendable type 'ViewModel' in a @Sendable closure
```

**Fix:** Make ViewModel Sendable or use `@MainActor`.

## Integration with CI

### GitHub Actions example

```yaml
name: Lint
on: [push, pull_request]

jobs:
  swiftlint:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: SwiftLint
        run: |
          brew install swiftlint
          swiftlint --strict
```

### Pre-commit hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

swiftlint --strict --quiet
if [ $? -ne 0 ]; then
    echo "SwiftLint failed. Fix issues before committing."
    exit 1
fi
```

## Peripheral Tooling

### swift-format

Apple's official formatter, good for consistency:

```bash
swift-format lint --recursive Sources/
swift-format format --in-place --recursive Sources/
```

### SwiftFormat (Nick Lockwood)

Alternative formatter with more rules:

```bash
swiftformat . --swiftversion 6.0
```

Relevant rules:
- `redundantAsync`: Removes unnecessary async
- `sortImports`: Organizes imports

### Periphery

Finds unused code:

```bash
periphery scan
```

Can find unused async functions.

## Static Analysis Tips

### 1. Enable all warnings

```
GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
CLANG_WARN_SUSPICIOUS_MOVE = YES
```

### 2. Treat warnings as errors in CI

```
SWIFT_TREAT_WARNINGS_AS_ERRORS = YES
```

### 3. Use Xcode's static analyzer

Product → Analyze (⇧⌘B)

### 4. Review Xcode's concurrency diagnostics

Check Issue Navigator for concurrency-related warnings.

## Common Linting Patterns

### Pattern 1: Async function audit

Find all async functions and verify they await something:

```bash
grep -rn "func.*async" Sources/ | head -20
```

### Pattern 2: Check for DispatchQueue usage

```bash
grep -rn "DispatchQueue" Sources/
```

Should be minimal in Swift Concurrency codebases.

### Pattern 3: Find Task {} usage

```bash
grep -rn "Task {" Sources/
```

Review for proper error handling and lifecycle management.

## Summary Checklist

- [ ] SwiftLint with `async_without_await` enabled
- [ ] Custom rules for `Thread.sleep` and `DispatchQueue`
- [ ] Strict concurrency checking enabled
- [ ] Swift 6 language mode (when ready)
- [ ] CI integration for linting
- [ ] Pre-commit hooks for local validation

## Further Learning

For comprehensive project configuration, see [Swift Concurrency Course](https://www.swiftconcurrencycourse.com).
