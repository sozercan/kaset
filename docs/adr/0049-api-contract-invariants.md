# ADR-0049: API Request, Cache, and Pagination Invariants

## Status

Accepted

## Context

The YouTube and YouTube Music clients share transport and cache infrastructure, but their wire identities and response scopes differ. Actor isolation does not prevent a request from resuming after a newer request, account transition, or cache invalidation.

## Decision

### Request identity and transport

- Keep signing and the `Origin`, `Referer`, and `X-Origin` headers on the client's own origin, as in [ADR-0020](0020-youtube-source-toggle.md). Take one cookie snapshot per request so the cookie header and signature use the same data without repeated WebKit cookie-store reads.
- Select a brand identity with `context.user.onBehalfOfUser`, not an auth-user index. An unauthenticated request must never carry a delegated identity left over from an earlier session.
- Let `URLSession` negotiate `Accept-Encoding`. Setting that header manually can disable transparent decompression, causing JSON or HTML parsing to fail on compressed responses such as the YouTube consent page. `APISessionConfigurationTests` guards the header configuration.

### Cache reads and writes

- Build the cache key from the request body with its actual client context and auth outcome. Keep guest responses separate from authenticated responses. A primary-account label is not an owner identity: the Music account-scope provider distinguishes the authenticated Google owner and selected YouTube identity.
- YouTube may reuse authenticated responses in an unresolved `pending` scope until account resolution. A resolved identity uses a different key. Where unresolved content was already shown, account resolution goes through the account-switch reset; the first resolution before authenticated content has rendered skips that teardown. A scope key alone is not an invalidation check: sign-out can invalidate a request even if its key has not changed.
- Allocate the write ticket before awaiting auth headers; claim the key only once its actual scope is known. For writes to the same key, later requests supersede earlier ones even if header construction completes in reverse order. Full invalidation and matching prefix invalidation also reject outstanding writes. Preserve ordering state until older outstanding tickets can no longer claim the key. See `APICacheTests`.
- Parse the shared YouTube Home response off the main actor, deriving the feed, chips, and titled shelves in one parse. Only cache the raw response after parsing succeeds; even an HTTP 200 can carry non-JSON. Before writing Home bytes, recheck the original scoped key as well as the write reservation.

### Continuation ownership

- An older initial-page or continuation request must not publish a cursor after a newer load supersedes it. YouTube Home also checks task cancellation after the detached parse before publishing its cursor; a discarded view model may belong to a different account.
- Preserve a Music browse continuation after cancellation. Appending a page can push the bottom-of-scroll sentinel out of the lazy stack and cancel its task. That cancellation does not establish that the server has no next page; the next appearance must be able to retry.

### Parse by ownership and wire shape

- Playlist continuations belong to the authoritative track shelf, never to suggestions or recommended tracks in the same response. Use section-level continuation only when the recognized shape has no track list of its own. Parse editability from known option-renderer wrappers, not an arbitrary menu title or deeply nested endpoint. For metadata runs, linked artist fields take precedence, but keep explicit unlinked creator text; do not interpret a navigable album title as a duration.
- Keep synthetic IDs stable across refreshes. A moods/genres browse ID can recur with different routing parameters, so include the parameters in the card identity. Treat color fields as ARGB on the wire. The dedicated Library playlist list is authoritative where it overlaps the landing page, but retain landing-only items. See [ADR-0031](0031-saved-album-library-reconciliation.md).
- Take the brand page ID and sign-in URL from the relevant identity tokens, resolving relative sign-in URLs against the YouTube origin. Artist “See all” destinations surface only recognized page types; classify carousel entries by renderer and endpoint, using shelf titles for ambiguous album/single cases. The Videos shelf is still out of scope pending the routing decision in [ADR-0018](0018-artist-page-episodes.md).
- Use signed minutes from UTC (`TimeZone.secondsFromGMT() / 60`), not JavaScript's opposite-signed `Date.getTimezoneOffset()` result. API Explorer mirrors this calculation rather than importing the Kaset executable target. Cache hashing separates the normalized JSON and brand bytes with a delimiter.

### API Explorer probes

- Keep the read-only probes distinct from live actions. `discover` validates endpoints and body fields against an allowlist: a `browse` with form data can change account state, so only the supported chart-country form is accepted. Ask request-profile parity requires explicit signed-in evidence and validates the exact prompt-free bootstrap `get_panel` command from `next`, even if `next` already includes a summary chip. See [ADR-0032](0032-youtube-ask-gemini.md).
- Keep the identity fixed across a probe. `discover` freezes the cookie snapshot across all hops, including an empty snapshot for guest use. Ask audit and parity reject explicit brand and auth-user selection; the watch-page fetch cannot guarantee it shares the selected identity of the API requests. The separate Ask free-text validator rechecks the cookie export and account selectors after asynchronous configuration discovery. Production Ask fences conversation state by the verified primary-account scope and authentication generation.
- Prefer schema and classification output over payloads. The `discover` report uses bounded traversal and a redacted rendering, including in verbose mode and when saved. Ask parity reports profile outcomes without printing opaque commands. These guarantees are specific to those report paths: arbitrary server diagnostic text is not assumed safe, and legacy/raw-output commands are not covered by a universal redaction guarantee.
- Track the legacy account-discovery and identity-classification limitations in [#616](https://github.com/sozercan/kaset/issues/616), saved-response diagnostic redaction in [#617](https://github.com/sozercan/kaset/issues/617), and cookie-domain matching in [#618](https://github.com/sozercan/kaset/issues/618).
- Do not fall back to a legacy cookie export when the debug app's own sandbox support directory exists. Its absence after sign-out is authoritative. Account sign-in probes use an ephemeral session and do not update the app's archive. Report landing host and path, not query parameters or opaque identity material.

## Consequences

Changes in wire shape or request ownership can affect pagination, account isolation, and what gets displayed together. Confirm changed shapes against the API Explorer and with synthetic fixtures before updating code. Follow up on the unused playlist duplicate option ([#620](https://github.com/sozercan/kaset/issues/620)), cache-key serialization failures ([#621](https://github.com/sozercan/kaset/issues/621)), and English-only played-state fallback ([#622](https://github.com/sozercan/kaset/issues/622)).
