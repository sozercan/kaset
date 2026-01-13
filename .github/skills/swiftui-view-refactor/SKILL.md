---
name: swiftui-view-refactor
description: Refactor and review SwiftUI view files for consistent structure, dependency injection, and Observation usage. Use when asked to clean up a SwiftUI view's layout/ordering, handle view models safely (non-optional when possible), or standardize how dependencies and @Observable state are initialized and passed.
---

# SwiftUI View Refactor

## Overview

Apply a consistent structure and dependency pattern to SwiftUI views, with a focus on ordering, Model-View (MV) patterns, careful view model handling, and correct Observation usage.

## Core Guidelines

### 1) View ordering (top → bottom)

- Environment
- `private`/`public` `let`
- `@State` / other stored properties
- computed `var` (non-view)
- `init`
- `body`
- computed view builders / other view helpers
- helper / async functions

### 2) Prefer MV (Model-View) patterns

- Default to MV: Views are lightweight state expressions; models/services own business logic.
- Favor `@State`, `@Environment`, `@Query`, and `task`/`onChange` for orchestration.
- Inject services and shared models via `@Environment`; keep views small and composable.
- Split large views into subviews rather than introducing a view model.

### 3) Split large bodies and view properties

- If `body` grows beyond a screen or has multiple logical sections, split it into smaller subviews.
- Extract large computed view properties (`var header: some View { ... }`) into dedicated `View` types when they carry state or complex branching.
- It's fine to keep related subviews as computed view properties in the same file; extract to a standalone `View` struct only when it structurally makes sense or when reuse is intended.
- Prefer passing small inputs (data, bindings, callbacks) over reusing the entire parent view state.

Example (extracting a section):

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 16) {
        HeaderSection(title: title, isPinned: isPinned)
        DetailsSection(details: details)
        ActionsSection(onSave: onSave, onCancel: onCancel)
    }
}
```

Example (long body → shorter body + computed views in the same file):

```swift
var body: some View {
    List {
        header
        filters
        results
        footer
    }
}

private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title2)
        Text(subtitle).font(.subheadline)
    }
}

private var filters: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack {
            ForEach(filterOptions, id: \.self) { option in
                FilterChip(option: option, isSelected: option == selectedFilter)
                    .onTapGesture { selectedFilter = option }
            }
        }
    }
}
```

Example (extracting a complex computed view):

```swift
private var header: some View {
    HeaderSection(title: title, subtitle: subtitle, status: status)
}

private struct HeaderSection: View {
    let title: String
    let subtitle: String?
    let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.subheadline) }
            StatusBadge(status: status)
        }
    }
}
```

### 4) View model handling (only if already present)

- Do not introduce a view model unless the request or existing code clearly calls for one.
- If a view model exists, make it non-optional when possible.
- Pass dependencies to the view via `init`, then pass them into the view model in the view's `init`.
- Avoid `bootstrapIfNeeded` patterns.

Example (Observation-based):

```swift
@State private var viewModel: SomeViewModel

init(dependency: Dependency) {
    _viewModel = State(initialValue: SomeViewModel(dependency: dependency))
}
```

### 5) Observation usage

- For `@Observable` reference types, store them as `@State` in the root view.
- Pass observables down explicitly as needed; avoid optional state unless required.

## Workflow

1) Reorder the view to match the ordering rules.
2) Favor MV: move lightweight orchestration into the view using `@State`, `@Environment`, `@Query`, `task`, and `onChange`.
3) If a view model exists, replace optional view models with a non-optional `@State` view model initialized in `init` by passing dependencies from the view.
4) Confirm Observation usage: `@State` for root `@Observable` view models, no redundant wrappers.
5) Keep behavior intact: do not change layout or business logic unless requested.

## Notes

- Prefer small, explicit helpers over large conditional blocks.
- Keep computed view builders below `body` and non-view computed vars above `init`.
- For MV-first guidance and rationale, see `references/mv-patterns.md`.

## Large-view handling

- When a SwiftUI view file exceeds ~300 lines, split it using extensions to group related helpers. Move async functions and helper functions into dedicated `private` extensions, separated with `// MARK: -` comments that describe their purpose (e.g., `// MARK: - Actions`, `// MARK: - Subviews`, `// MARK: - Helpers`). Keep the main `struct` focused on stored properties, init, and `body`, with view-building computed vars also grouped via marks when the file is long.
