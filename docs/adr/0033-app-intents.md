# ADR-0033: App Intents for Shortcuts, Siri, and Spotlight

## Status

Accepted

## Context

Issue #520 asks for Shortcuts actions, Siri control, and Spotlight search. Apple's App Intents framework covers all three. It does not need the paid-only SiriKit entitlement, but it puts two constraints on Kaset:

1. **Build metadata.** The system discovers intents from `Contents/Resources/Metadata.appintents`. Xcode generates it in an "Extract App Intents Metadata" build phase. Kaset is assembled from `swift build` output by `Scripts/build-app.sh`, which has no such phase: neither `swift build` nor `xcodebuild` on the package produces the metadata.
2. **Signing.** `linkd` refuses to connect to an app without a team identity ("Rejecting invalid client due to requiresValidatedBundle"). An ad-hoc signed app lists its actions in Shortcuts but cannot run them. A free Personal Team "Apple Development" certificate is enough, and release builds already use one.

Intents also run outside the SwiftUI view tree. The system creates intent and entity-query values itself, so they cannot read environment values, and an intent can arrive during a cold launch before sign-in state is restored.

## Decision

### Build

`build-app.sh` reproduces Xcode's metadata phase:

- `swift build` runs with `-emit-const-values` and the frontend flag `-const-gather-protocols-file Scripts/app-intents-const-protocols.json`, which produce the compiler output the processor consumes. (Xcode 27 uses the driver flag `-const-gather-protocols-list`, but Swift 6.2 in Xcode 26 does not have it.)
- After each architecture builds, the app module's `.swiftconstvalues` are staged next to its thin binary. Swift Build (Xcode 27) and the native build system (Xcode 26) write them in different places.
- `xcrun appintentsmetadataprocessor` runs with Xcode's flags against the first architecture's binary and const values, writing `Metadata.appintents` into the bundle. The build fails if the metadata is missing.
- App Shortcut phrases are localized through their own table. `Sources/Kaset/Resources/AppShortcuts.xcstrings` (Xcode's format: one key per shortcut, holding a string set of phrases per language) is compiled into the main bundle. It is excluded from SwiftPM resources and has no `.lproj` mirror, because only packaged builds carry metadata. The build fails when the catalog's keys differ from the phrases the processor extracted, when a shipped language has no phrases, or when a translation drops a placeholder.
- `Scripts/verify-release-app.sh` checks that the metadata and phrase tables are present.

### Runtime

- `AppIntentsBridge` is a `@MainActor` singleton configured in `KasetApp.init`, the same pattern as `PlayerService.shared` for AppleScript. Intents and queries are thin wrappers over it.
- Playback intents wait on the same readiness gate as deep links (startup cleanup done, auth not initializing), then bring the main window forward the way `kaset://play` does, because the playback WebView lives in that window. They use the existing playback paths: `playWithRadio`, `PlaylistPlaybackActions`, and `AlbumPlaybackActions`. They return once playback starts (a long playlist keeps paging in afterward) and fail when the content does not load, has nothing playable, or newer playback replaces it first.
- Transport intents (play, pause, next, previous) enter through `NowPlayingManager.handleAppIntentCommand`, the same ingress as the media keys. That gives them the existing command serialization and music/video routing. They report that nothing is playing when no video is routed and the music player has no track or queue. A new `trackNavigation` payload changes track regardless of the media-control-style setting, which otherwise turns next/previous into a ±15 s seek.
- Like/dislike intents set a rating idempotently through `PlayerService.rateCurrentTrack`, which the player-bar toggles also use, and report failure if YouTube Music rejects it.
- `MainWindow` publishes the signed-in Library (playlists and saved albums) to the bridge once it has loaded. `SpotlightLibraryIndexer` replaces the Spotlight index from that snapshot, debounced, one replacement at a time, retrying a failed one a few times. An empty snapshot (signed out, guest, or an account switch) clears it, so another account's items do not linger. The same change refreshes App Shortcut parameters for "Play *playlist* in Kaset".
- `PlayPlaylistIntent` and `PlayAlbumIntent` are the entities' `OpenIntent`s, so choosing an indexed item in Spotlight plays it.

## Consequences

- Shortcuts, Siri, and Spotlight work in signed release builds, without a paid developer account.
- CI dev builds stay ad-hoc signed, so their intents are listed but do not run. Local packaged builds (`KASET_SIGNING=dev`) work when an Apple Development certificate is installed.
- The const-value protocol list mirrors Xcode's and may need updating when App Intents adds extractable protocols.
- Adding or changing an App Shortcut phrase requires a matching `AppShortcuts.xcstrings` entry in every language, or the packaged build fails.
- Spotlight indexes only what the Library view already loaded; liked songs are not indexed individually.
