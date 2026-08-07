# ADR-0013: Localization Strategy (String Catalogs)

## Status

Proposed

## Context

Kaset localizes ~360 user-facing strings via String Catalogs and checked-in `.lproj` bundles. Arabic was the first target language; the app now ships UI translations for seventeen locales, with additional languages added incrementally.

Supported UI locales: `ar`, `de`, `en`, `es`, `fr`, `id`, `it`, `ko`, `nl`, `pl`, `pt`, `ru`, `sv`, `tr`, `uk`, `zh-Hans`, `zh-Hant`. The Settings → General → Language picker lists **System Default** first, then explicit languages in locale code order.

Most locales are plain ISO 639-1 codes, but Chinese is identified by **script** rather than region, matching Apple's localization identifiers (`zh-Hans`, `zh-Hant`) rather than region codes such as `zh-CN`/`zh-TW`. A user whose preferred language is `zh-Hant-TW` or `zh-Hant-HK` resolves to `zh-Hant`, so one traditional bundle serves both. `zh-Hant` follows Taiwan usage, since CLDR expands the bare tag to `zh-Hant-TW` and YouTube's own `zh-Hant` responses use Taiwan vocabulary. Hong Kong (`zh-HK`) is a separate Apple localization and is not currently shipped; adding it later is purely additive.

These same codes are valid InnerTube `hl` values — verified by probing `browse FEmusic_home` with each — so `ContentLanguage.apiLanguageCode` needs no separate mapping for Chinese.

Requirements:
1. **Minimal disruption** — Adding localization should not require architectural changes
2. **SwiftPM-first compatibility** — Kaset builds primarily via SwiftPM, with checked-in Xcode projects for app and UI-test workflows
3. **Modern tooling** — Leverage Swift 6 / Xcode 16+ capabilities
4. **Arabic support** — Must handle RTL layout, Arabic plural forms (6 categories), and mixed-language content
5. **Maintainability** — New strings added by contributors should be easy to localize

The repo is SwiftPM-first, but it also includes `Kaset.xcodeproj` and `KasetUITests.xcodeproj` for app packaging, runtime debugging, and UI-test workflows.

## Decision

### String Catalogs (`.xcstrings`)

Use Xcode String Catalogs (`Localizable.xcstrings`) as the source of truth for all translatable strings. This is Apple's modern replacement for `.strings` / `.stringsdict` files, introduced in Xcode 15.

The catalog lives at `Sources/Kaset/Resources/Localizable.xcstrings`. Because current SwiftPM/Xcode 26 builds can produce duplicate `.strings` outputs when processing both the catalog and checked-in `.lproj` resources, `Package.swift` excludes the catalog and processes generated `*.lproj` directories for SwiftPM/runtime resource bundles. The app packaging script (`Scripts/build-app.sh`) compiles the source catalog into both the packaged app resources and the Kaset SwiftPM resource bundle so packaged builds still come from the catalog.

When updating translations, regenerate the checked-in `Sources/Kaset/Resources/*.lproj/Localizable.strings` files from `Localizable.xcstrings` so SwiftPM builds and packaged app builds stay in sync.

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
- **Manual translations needed** — No automated translation pipeline; each string requires manual translation per locale
- **No CLI auto-extraction** — Auto-extraction (above) only runs in Xcode builds. The repo's day-to-day workflow is CLI-first (`swift build`), which compiles new `LocalizedStringKey`/`String(localized:)` literals fine but does **not** write the new keys back into `Localizable.xcstrings` — missing keys silently fall through to the literal English at runtime with no error. When adding strings via the CLI workflow, hand-add each new key to `Localizable.xcstrings` (with values for every supported locale) and regenerate or hand-update the checked-in `Sources/Kaset/Resources/*.lproj/Localizable.strings` files in the same change, because those `.lproj` files are the runtime source for language overrides in SwiftPM builds. When adding a new locale, also register its `.lproj` in `Package.swift`, add a `SettingsManager.ContentLanguage` case, and extend localization tests.

### Neutral
- SwiftUI's implicit `LocalizedStringKey` means many `Text("…")` calls already work — they just need the catalog to contain the key
- The `.xcstrings` JSON format is diffable in Git, though merge conflicts are possible with concurrent string additions
