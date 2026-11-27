# ADR-0044: Share Artwork Downloads Without Serializing Decodes

## Status

Accepted

## Context

Kaset displays the same artwork in small cards and larger playback surfaces. URL-only decoded caching lets a small prefetch make larger artwork blurry. Serializing disk reads and ImageIO decoding on the cache actor also delays visible cards during scrolling.

## Decision

- Store raw downloads per URL, but key decoded images and in-flight decode tasks by URL and requested size. Register the size-specific task before the first suspension so prefetch and display share work. Different sizes reuse raw bytes but decode separately; requested dimensions are in display points and downsampling accounts for display scale.
- Allow AppKit cells to check the thread-safe in-memory cache synchronously without hopping to the actor. Do disk reads and decoding off the actor so visible cards can decode in parallel. Bound prefetch concurrency and retain structured cancellation when the owning view disappears.
- Cache artwork-derived palettes by URL and target size, reusing the image cache. Sample a small image off the main actor and favor saturated pixels while excluding near-black and near-white samples. This keeps detail-accent extraction inexpensive and avoids sampling neutral borders as the dominant color.
- Reconcile an approximate disk-size counter periodically and after crossing the cap instead of scanning after every write. A single directory pass gives the exact retained size and eviction candidates. Cache reads do not change file modification dates, so eviction is by oldest write, not by least recent read.

## Consequences

Artwork stays sharp across sizes without duplicate downloads. Rebuilding AppKit cells on the scroll path can use existing images without blocking on disk. The disk counter is eventually reconciled when external changes make it inaccurate.
