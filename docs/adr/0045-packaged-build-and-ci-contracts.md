# ADR-0045: Preserve Packaged App Contracts Across Toolchains

## Status

Accepted

## Context

SwiftPM produces build products, not a complete Kaset app bundle. CI also tests both the oldest supported macOS UI and newer system integrations. A build that compiles can still break signing, Liquid Glass, Spotlight, or the fallback UI if packaging treats the toolchains as interchangeable.

## Decision

- Query SwiftPM for the product directory, keeping fallbacks for native and Swift Build layouts. Stage each thin executable and the matching App Intents metadata inputs immediately: architecture builds may report the same output directory. Do not collect debug metadata from deleted sources. See [ADR-0033](0033-app-intents.md) for the metadata and signing contract.
- Keep the executable's linked SDK separate from its deployment target. macOS uses the Mach-O SDK for linked-on-or-after checks, including Liquid Glass. The current `vtool` fixup is tracked in [#608](https://github.com/sozercan/kaset/issues/608). Re-sign after changing the SDK or Sparkle rpath; unsigned packaging also needs a valid ad-hoc executable signature on Apple silicon. Sign the staged executable outside the bundle before sealing bundle resources. Sign Sparkle's nested installer services before the framework and app; their identifiers derive from the bundle identifier.
- Put Icon Composer assets and AccentColor in the main bundle's `Assets.car`, separate from the SwiftPM resource bundle's catalog, which serves `Bundle.module`. An asset compilation failure should fail packaging, except that the macOS 15 UI-test build can explicitly omit the main catalog until [#609](https://github.com/sozercan/kaset/issues/609) is resolved. The CI UI job registers its packaged application with Launch Services before running `XCUIApplication`.
- Exercise fallback UI on Sequoia and Liquid Glass and Apple Intelligence paths on Tahoe. Serialize test suites that share app singletons, playback document state, or standard preferences. The Sequoia SwiftPM job skips XCTest discovery pending [#607](https://github.com/sozercan/kaset/issues/607); the release job still runs the XCTest suites.
- Keep debug bundles under a distinct identifier: their sandbox, cookies, and preferences must not be shared with the release app. An ad-hoc dev build can list its App Intents but cannot run them. Releases use the full Git history for changelog generation.
- Prefer Developer ID signing and notarization for releases; use a configured Apple Development certificate if Developer ID is unavailable, and ad-hoc signing as the last resort. Constrain CI's imported private key to the signing tool and clean up temporary signing material. Homebrew's `:sequoia` requirement cannot express Kaset's 15.4 patch minimum; `LSMinimumSystemVersion` and the appcast enforce it. Appcast changes use a short-lived pull request because the default branch is protected.

## Consequences

Packaged validation is distinct from compiling the Swift package. An SDK, packaging, signing, or runner change must preserve the bundle and CI contracts above; the tracked toolchain workarounds can be removed independently once verified.
