# ADR-0032: Watch-Scoped YouTube Ask Gemini

## Status

Accepted; production activation uses the explicitly selected fixed WEB profile.

## Context

YouTube exposes an undocumented Ask Gemini / YouChat surface on some watch
pages. The surface is account-, rollout-, client-, and video-dependent. Its
responses combine user-visible messages and suggestion labels with opaque
server commands that must be replayed exactly. Those commands can carry
session- or conversation-specific state and must not become application data,
logs, fixtures, restoration state, or telemetry.

Kaset normally retrieves product data through `YouTubeClient` and reserves
WebViews for authentication and DRM playback. Implementing Ask through watch-page
DOM automation would expand the WebView's responsibility, couple the feature to
frontend markup, and make account and lifecycle boundaries harder to enforce.
The app also needs a deliberately smaller first version than YouTube's full
surface: generating an answer from arbitrary text or adopting an unvalidated
streaming transport would require request fields and semantics that have not
been established safely.

The exact production request profile is a separate compatibility question. A
successful exploratory request does not prove that the profile used by
`YouTubeClient` is accepted, so activation must be gated by a redacted,
read-only parity check rather than by inferred or guessed request fields.
Wire-level observations and the API Explorer workflow remain documented in the
[API discovery record](../api-discovery.md#youtube-ask-gemini--youchat-investigation-2026-07-27).

## Decision

1. **Use the API, not the playback WebView.** Ask discovery, panel
   materialization, and suggestion submission belong to `YouTubeClient` and a
   Foundation-only `YouTubeAskCore` parser/decoder layer. The existing watch
   `next` response is shared with normal watch-page parsing. WebViews remain
   limited to authentication and DRM playback; Kaset does not scrape or drive
   the Ask Gemini DOM.
2. **Ship a chips-only v1.** An eligible watch page exposes a sparkles action
   in the top toolbar. Activating it presents a transient, top-centered glass panel
   and may prepare the initial panel, but never submits a suggestion or generates
   an answer automatically. Outside click, Escape, or the panel header
   dismisses the surface without discarding the current watch-scoped conversation.
   Only server-issued
   suggestion chips and follow-up chips can be selected. Arbitrary text prompts,
   a text composer, and `streaming_panel` are out of scope.
3. **Scope all conversation state to the current watch and account.** Ask is
   available only to an eligible signed-in primary account. Hidden state is
   bound to the video, authentication generation, primary-account scope, local
   conversation ID, and conversation revision. Navigation away, source or
   account changes, authentication changes, cancellation, or view-model
   destruction discards the state. Conversations are memory-only and are never
   stored in `APICache`, UserDefaults, Keychain, navigation restoration,
   telemetry, or logs.
4. **Treat server commands as opaque capabilities.** Continuations and related
   command objects have no printable, codable, raw-value, or persistence-facing
   interface. Kaset preserves server order, replays only the exact command
   selected by the user, and never substitutes the visible chip label or an
   invented conversation field. Only sanitized visible messages and local IDs
   cross into UI models. Server-provided suggestion labels and answers are
   displayed verbatim and are not localized by Kaset.
5. **Fail closed on unsupported or ambiguous data.** Strict parsing recognizes
   only confirmed YouChat structures, bounded wire formats, and supported
   message/chip containers, including the confirmed singular
   `onResponseReceivedCommand.listMutationCommand` insertion path. Result/link
   view models and sibling framework updates remain outside the visible model.
   A chip may carry the exact observed
   `onClick.listMutationCommand` UI mutation, which is ignored rather than
   preserved or executed only when its inserted user-turn text matches the chip
   label and every key matches the allowlisted local user-turn/loading-animation
   insertion and scroll shape. Any other callback rejects the chip set. Multiple
   panel-bootstrap commands reject the
   bootstrap unless validated direct chips make panel materialization unnecessary,
   in which case Kaset discards every ambiguous panel command. Other ambiguity,
   malformed or oversized responses, unsupported decorators, identity changes,
   or uncertain submission outcomes disable the current session. There is no
   automatic retry for panel materialization or suggestion submission; the
   read-only watch bootstrap may retry once only after an internal identity-fence
   cancellation while the same route load remains current. The UI may offer New
   Chat, which starts from a fresh watch bootstrap and replaces the old
   conversation only after preparation succeeds.
6. **Select the production request profile explicitly.** The production app
   selects the fixed WEB profile. The July 28, 2026 parity run was inconclusive
   because the exported session appeared signed out; activation was subsequently
   enabled by explicit product direction on July 30, 2026. Compatibility
   configuration remains isolated to Ask requests, and malformed, ineligible, or
   identity-mismatched responses continue to fail closed. The
   [API discovery record](../api-discovery.md#youtube-ask-gemini--youchat-investigation-2026-07-27)
   is the sole wire-level source of truth.

## Consequences

- Ask follows Kaset's API-over-WebView boundary and shares one strict parser and
  safety implementation between the app and API Explorer.
- V1 cannot accept free-form questions and does not reproduce every YouTube Ask
  capability. It can only replay suggestions YouTube issued for the current
  conversation.
- Conversation continuity intentionally ends at the watch/account lifecycle
  boundary and at app termination.
- Opaque command material is harder to inspect during debugging, but accidental
  disclosure and cross-account reuse are substantially less likely.
- The panel remains invisible for signed-out, guest, brand-account, and
  server-ineligible watch routes even though the production capability is enabled.
- Future request-profile changes require updating the redacted parity result and
  tests, not guessing request fields or weakening parser rules.
