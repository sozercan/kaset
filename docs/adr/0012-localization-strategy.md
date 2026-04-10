# ADR-0012: Localization Strategy (String Catalogs)

## Status

Proposed

## Context

Kaset has no localization infrastructure. All ~300 user-facing strings are hardcoded English literals in SwiftUI views, models, and services. Arabic is the first target language, with potential for additional languages later.

Requirements:
1. **Minimal disruption** — Adding localization should not require architectural changes
2. **SwiftPM-first compatibility** — Kaset builds primarily via SwiftPM, with checked-in Xcode projects for app and UI-test workflows
3. **Modern tooling** — Leverage Swift 6 / Xcode 16+ capabilities
4. **Arabic support** — Must handle RTL layout, Arabic plural forms (6 categories), and mixed-language content
5. **Maintainability** — New strings added by contributors should be easy to localize

The repo is SwiftPM-first, but it also includes `Kaset.xcodeproj` and `KasetUITests.xcodeproj` for app packaging, runtime debugging, and UI-test workflows.

## Decision

### String Catalogs (`.xcstrings`)

Use Xcode String Catalogs (`Localizable.xcstrings`) as the single source of truth for all translatable strings. This is Apple's modern replacement for `.strings` / `.stringsdict` files, introduced in Xcode 15 and fully supported in SPM packages with `defaultLocalization` set.

The catalog lives at `Sources/Kaset/Resources/Localizable.xcstrings` and is processed by the existing `.process("Resources")` rule in `Package.swift`.

### String Wrapping Patterns

| Context | Pattern | Example |
|---------|---------|---------|
| Static `Text` in SwiftUI | Implicit `LocalizedStringKey` | `Text("Home")` |
| Computed properties, models, non-SwiftUI | `String(localized:)` | `String(localized: "Home")` |
| Interpolated strings | `String(localized:)` with interpolation | `String(localized: "\(count) songs")` |
| Accessibility labels (string concatenation) | `String(localized:)` | `.accessibilityLabel(String(localized: "Play"))` |
| Plurals | String Catalog plural variants | Configured in `.xcstrings` per-key |

### Enum Display Names

Enums that use `rawValue` as display text (`NavigationItem`, `SearchFilter`, `LibraryFilter`, `LaunchPage`) will gain a `displayName` computed property using `String(localized:)`. The `rawValue` remains a stable English identifier for persistence and logic.

### What Is NOT Localized

- AI system prompts and instructions (LLM-facing, not user-facing)
- Log messages via `DiagnosticsLogger`
- API request parameters
- System image names

## Consequences

### Positive
- **Single file** — All translations live in one `.xcstrings` file, easy to review and maintain
- **Xcode integration** — String Catalog editor shows translation status, flags missing translations
- **Auto-extraction** — Xcode can detect new `LocalizedStringKey` usage and add keys automatically
- **Plural support** — Built-in support for Arabic's 6 plural categories (zero, one, two, few, many, other)
- **No dependencies** — Pure Apple tooling, no third-party localization libraries
- **Incremental** — Strings can be wrapped and translated in small PRs without breaking existing behavior

### Negative
- **SPM + xcstrings is relatively new** — Less community precedent than `.strings` files in SPM; Phase 0 validates this before committing
- **Large initial diff** — Wrapping ~300 strings touches many files, but this is spread across multiple focused PRs
- **Manual Arabic translations needed** — No automated translation pipeline; each string requires manual Arabic translation

### Neutral
- SwiftUI's implicit `LocalizedStringKey` means many `Text("…")` calls already work — they just need the catalog to contain the key
- The `.xcstrings` JSON format is diffable in Git, though merge conflicts are possible with concurrent string additions
