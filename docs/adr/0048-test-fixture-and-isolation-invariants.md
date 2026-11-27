# ADR-0048: Test Fixture and Isolation Invariants

## Status

Accepted

## Context

Kaset's tests exercise undocumented response formats, Apple frameworks with OS-specific behavior, and services that ordinarily share app state. Some fixture details look incidental but are necessary to reproduce a regression or keep a test isolated.

## Decision

### Preserve the boundary under test

- Use captured, sanitized responses when a renderer's nesting or distinction between fields is the regression trigger. Keep the legacy and current shapes distinct. For example, `PlaylistQueueParserTests` needs display-only short bylines alongside linked long bylines, and `YouTubeResponseParserTests` needs the filter chip bar nested in the rich-grid header. Storyboard fixtures preserve the template and sheet layout but use placeholder signature values.
- Exercise the real API Explorer queue-probe parsing and output code with synthetic responses and no live cookie loading or network. The privacy harness checks that redaction preserves payload shape without depending on sensitive field names or dictionary order. For API request fixtures, `URLProtocol` may receive the HTTP body as a stream rather than `httpBody`. Check both forms; leave `Accept-Encoding` to URLSession so responses are transparently decompressed.
- JavaScriptCore test contexts are not browser pages. Supply the `window`, DOM, and browser `URL` behavior the specific playback script needs; do not replace the script being exercised. In contrast, the WebAuthn suppression suite needs a secure-origin `WKWebView`: its baseline checks that the credential surface is present before the suppression test can prove anything. Its navigation waiter must finish on cancellation and content-process termination as well as normal completion.
- Keep platform-dependent inputs reproducible where possible. Use fixed UTC offsets for InnerTube assertions rather than named zones whose offsets change with daylight saving. The Bengali romanization fixture deliberately places combining marks before a token that can lack a Latin transcription; it exercises the UTF-16 range fallback without requiring a particular tokenizer result across macOS versions.
- Keep the source-catalog and runtime-bundle localization assertions separate. Packaged builds use the catalog; runtime overrides read the checked-in `.lproj` mirrors. Simplified and Traditional Chinese sentinel values should differ in wording, not just glyph shape, so a swapped or mechanically converted locale cannot pass both checks.

### Keep tests independent

- Prefer a private `UserDefaults` domain, storage directory, or injected no-op collaborator over the developer's preferences, cookie archive, audio engine, or Spotlight index. Use per-session `MockURLProtocol` handlers and reset the same session; a global reset does not clear per-session entries.
- A `.serialized` suite only serializes its own tests. Keep library mutation tests under the same gate while they exercise the process-wide coordinator, cookie quarantine and login recovery in the same suite while they share the restore generation, and scripting cases that replace `PlayerService.shared` together. Keep queue persistence checks on a private defaults domain, including when testing restoration across service instances. Compare decoded cookies, not re-encoded archive bytes; keep the shipped invalidation key stable so existing sign-outs remain authoritative.
- Inject Smart Shuffle preferences for the ordinary queue tests. The regression check for the production default provider intentionally changes `SettingsManager.shared`; keep the mutation and deferred restoration on the main actor with no suspension between them. Use cancellation-aware gates when production will cancel and await an in-flight mock. To assert that newer work wins, hold the old call open until the new work has had a chance to finish rather than guessing an overlap with a fixed delay.
- Run live Apple Intelligence checks separately from mock-driven command and routing tests, with an availability gate. Use a new model session per attempt and check semantic fields without expecting exact model wording.

### Test the macOS integration at the right level

- Unit smoke tests construct and, where needed, host view values. They are not a substitute for launching macOS 15 and macOS 26 UI test lanes. UI tests address an app in a separate process, so their accessibility identifiers mirror the app's and must change with them. Prefer identifier or selector lookups over localized labels; when the fallback and current rows have different SwiftUI accessibility wrappers, accept either the text or its enclosing button.
- For a test of an `AppDelegate` menu action, keep a strong reference to the service the delegate holds weakly. Otherwise, an unintended nil-player case can pass in place of the live-player/no-track case. Await the observable update rather than assuming Objective-C action dispatch completed synchronously.

## Consequences

Changes to the recorded boundaries should update the corresponding fixtures and checks together.

Current follow-ups are restoring excluded SwiftPM coverage ([#602](https://github.com/sozercan/kaset/issues/602)), using ordered search fixtures ([#605](https://github.com/sozercan/kaset/issues/605)), replacing runner detection ([#606](https://github.com/sozercan/kaset/issues/606)), strengthening UI assertions ([#623](https://github.com/sozercan/kaset/issues/623)), and isolating tests from shared helpers and host state ([#624](https://github.com/sozercan/kaset/issues/624)).
