# AGENTS.md

Guidance for AI coding agents working in this repository.

Kaset is a native macOS client for YouTube Music and YouTube, written in Swift 6 and SwiftUI. The deployment target is macOS 15.4, with macOS 26 features such as Liquid Glass layered on top. Write idiomatic SwiftUI and Swift Concurrency code that follows Apple's Human Interface Guidelines.

## Rules

- **Keep real credentials out of everything.** Cookies, SAPISID values, auth tokens, and API keys must not appear in code, comments, logs, docs, test fixtures, or your output. Use placeholders such as `"REDACTED"`, `"mock-token"`, or `"test-cookie"`. The repo is public and the app holds signed-in Google sessions, so a leaked value compromises a real account.
- **Ask before running UI tests.** They launch the app and take over the desktop.
- **Ask before adding a third-party dependency.** The project keeps them minimal; Sparkle, for app updates, is currently the only one.
- **Prefer the API clients over WebView.** Use `YTMusicClient` (YouTube Music) or `YouTubeClient` (YouTube) whenever the endpoint exists. WebView is only for DRM playback and sign-in.
- **Extend the API explorer instead of writing one-off scripts.** API exploration and debugging tooling belongs in `Sources/APIExplorer/main.swift` so the next person can reuse it.
- **Keep standard macOS shortcuts.** Don't rebind `⌘M`, `⌘W`, `⌘Q`, `⌘H`, or `⌘,` unless the human asks. For media shortcuts, follow macOS and Apple Music conventions and update `docs/keyboard-shortcuts.md`.
- **Record significant design changes** as an ADR in `docs/adr/`.

## Working Style

- Deliver what was asked, at the scope intended. Make routine judgment calls yourself, and check in only when different readings of the request would lead to materially different work.
- Match existing implementations: a new detail view follows the existing detail views, a new parser follows `Sources/Kaset/Services/API/Parsers/`.
- Adapt new code to existing public signatures, protocols, and model types instead of changing them, unless the task calls for it.
- If an approach goes wrong, revert and re-scope rather than layering patches on it.

## Build & Code Quality

```bash
swift build                              # Build
swift test --skip KasetUITests           # Unit tests (UI tests live in a separate Xcode project)
swiftlint --strict && swiftformat .      # Lint & format
```

A code change is done when these pass for the code you touched. Stay CLI-first; use Xcode or `xcodebuild` only for UI tests, runtime debugging, screenshots, or scheme-specific investigation.

`.swiftformat` uses `--self insert`: in static methods call other static methods as `Self.methodName()`, and in instance methods write `self.property` explicitly.

## Coding Rules

Project rules that differ from standard Swift/SwiftUI conventions and aren't mechanically checked:

| Avoid | Use | Why |
|-------|-----|-----|
| `.background(.ultraThinMaterial)` | `compatGlass(...)` helpers in `LiquidGlassCompat.swift`, or `.glassEffect()` behind `#available(macOS 26.0, *)` | Liquid Glass on macOS 26 with a macOS 15 fallback |
| Force unwraps (`!`) | Optional handling or `guard` | Project policy |

- Mark `@Observable` classes with `@MainActor`.
- Write new unit tests with Swift Testing (`@Test`, `#expect`).
- Throw `YTMusicError.authExpired` on HTTP 401/403.
- Use `.task` instead of `.onAppear { Task { } }`.

`swiftlint --strict` enforces the mechanically checkable bans (`print()`, `DispatchQueue`, `NavigationView`, `foregroundColor`, `cornerRadius`, `contentMargins`) and names the replacement in each message; see `.swiftlint.yml`.

## Localization

`Sources/Kaset/Resources/Localizable.xcstrings` is the source of truth. Packaged builds compile the catalog, but SwiftPM/Xcode runtime builds read the checked-in `Sources/Kaset/Resources/*.lproj/Localizable.strings` mirrors, so the two must change together or the build types diverge.

- When adding keys or changing translations, update the catalog first, then the matching `.lproj/Localizable.strings` files in the same change.
- Run `swift test --skip KasetUITests --filter LocalizationCatalogParityTests` after localization changes.
- Siri phrases for App Shortcuts live in `Sources/Kaset/Resources/AppShortcuts.xcstrings` (no `.lproj` mirror). `Scripts/build-app.sh` fails if it drifts from `KasetShortcuts`, so update it whenever a phrase changes.
- When adding a locale, also register its `.lproj` in `Package.swift`, add the `SettingsManager.ContentLanguage` case, and extend the localization tests.

## API Discovery

YouTube's response shapes are undocumented and change without notice, so a parser written from inference compiles and then silently returns nothing. Before adding or changing an API call, request shape, or response parser, verify the real request and response with `swift run api-explorer` (see the `api-exploration` skill). Prefer read-only probes. Get explicit approval from the human before sending a live request that changes account data.

## Debugging & Measurement

For bugs about timing, lifecycle, or "why didn't this run/load/update" (SwiftUI `.task` or state churn, cold-launch ordering, perceived latency), measure before fixing. Reasoning about SwiftUI lifecycle or async ordering from source alone is unreliable, and a short timestamped trace settles in one launch what hypothesizing cannot. Add the trace, reproduce, fix what the data points at, re-measure, then remove the instrumentation before committing.

The app is sandboxed, which breaks most ad-hoc logging without any error:

- `Logger`/`os_log` `.info` and `.debug` lines don't reliably appear in `log stream` or `log show`.
- Writes to a hardcoded `/tmp/...` path are blocked.
- Window-screenshot automation is unreliable.

Write throwaway traces to `NSTemporaryDirectory()`, `synchronize()` after each line, and read them from `~/Library/Containers/com.sertacozercan.Kaset/Data/tmp/` (`com.sertacozercan.Kaset.debug` for packaged debug builds). `docs/common-bug-patterns.md` has the trace template, the single-flight load pattern for the `.task`-restart cancellation deadlock, concurrency anti-patterns, and a pre-submit checklist.

### Cookie storage in debug builds

Sandboxed builds without a valid Developer ID or provisioning profile (local debug and ad-hoc builds) hang inside `SecItemCopyMatching` when they query the Keychain.

- `#if DEBUG` builds therefore store cookies in Application Support at `Kaset/cookies.dat` and skip the Keychain. Launch with `KASET_DEBUG_COOKIE_STORAGE=keychain` to test the production Keychain path.
- Packaged debug builds use the bundle ID `com.sertacozercan.Kaset.debug`, which gives them their own container, UserDefaults, and WebKit cookie jar. Don't package a debug build with the release bundle ID: each build's startup would overwrite the other's session.
- The Keychain is shared, so `KASET_DEBUG_COOKIE_STORAGE=keychain` reads and writes the release archive.
- The debug file backend has its own sign-out tombstone key (`authCookieBackupInvalidated.debugFileStorage`). Debug-only auth state must not write the release key.

## Code Review

Run the `autoreview` skill by default after committing non-trivial code changes and before pushing them. Skip it for docs-only or trivial changes, or when the human opts out. Finish the focused tests first, and don't run the review at the same time as tests: the CPU contention makes timing-sensitive tests flaky.

Use these Kaset settings with the skill, from the repository root:

```bash
python3 .agents/skills/autoreview/scripts/autoreview --mode branch --base origin/<base> --max-priority P3 \
  --source-context-file AGENTS.md \
  --prompt "Also report changes that violate the repository rules in the AGENTS.md source context, such as credential handling, API-over-WebView, localization parity, and the Coding Rules table."
```

`<base>` is the PR's base branch (`gh pr view --json baseRefName --jq .baseRefName`), or `main` when there is no PR yet. If that lookup fails for any other reason, such as auth or network, fix it or ask; don't assume `main`.

- `--max-priority P3` accepts findings at every priority (P0 through P3); the helper's default of P0 hides the rest in audit output.
- `--source-context-file AGENTS.md` gives the reviewer these repo rules as evidence, and `--prompt` asks it to check them; the helper treats source files as evidence, not instructions. `--source-context-file` only works in `branch` and `commit` modes; drop it when asked to review uncommitted work with `--mode local`.
- `branch` mode excludes uncommitted work, so format and commit your own changes first. For review-only requests, leave the checkout as it is.

Review findings are advisory, including P2 and P3: check each one against the real code path, fix the ones that hold up, and reject the rest only with a reason. After review-driven code changes, rerun the focused tests and the review once. When you report back, include the review command, the tests you ran, which findings you accepted or rejected and why, and the result of the final run.

`.agents/skills/autoreview/` is an unmodified copy of [`sozercan/skills`](https://github.com/sozercan/skills/tree/main/skills/autoreview) (commit `1b8ef21`), without that directory's own `AGENTS.md`/`CLAUDE.md`, which only govern maintenance of the source repository. Don't edit it in place: change the source repository, then replace the whole directory with the new version, again leaving out those two files.

## Skills

Repeatable, repo-specific workflows live in `.agents/skills/` (also exposed as `.claude/skills/`). Add new workflows there so this file stays focused on repo-wide rules.
