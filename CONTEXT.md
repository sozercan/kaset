# Kaset Domain Language

## App Source

The active content experience selected by the sidebar source toggle. `.music` is the YouTube Music experience and remains the default; `.video` is the regular YouTube experience. Source switches swap the visible navigation surface without merging the two data models.

## Music Experience

Kaset's YouTube Music surface: songs, albums, artists, playlists, podcasts, lyrics, queue management, and DRM audio playback through the hidden `SingletonPlayerWebView`. Data fetching belongs to `YTMusicClient` and music-specific parsers.

## YouTube Experience

Kaset's regular YouTube surface: recommendations, search, subscriptions, Shorts, channels, playlists, Watch Later, history, comments, and video playback through `YouTubeWatchWebView`. Data fetching belongs to `YouTubeClient` and YouTube-specific parsers under `Services/API/Parsers/YouTube/`.

## Playback Arbiter

The coordinator that keeps YouTube Music and regular YouTube from playing over each other. It pauses music when a YouTube video starts, pauses YouTube video when music starts, and lets media-key handling follow whichever source played most recently.

## Library

The signed-in user's saved YouTube Music collection. Kaset surfaces Music Library content as playlists, saved albums, followed artists, subscribed podcast shows, and uploaded songs. Regular YouTube has separate library-like surfaces such as subscriptions, Watch Later, liked videos, history, and playlists.

## Library Content Identity

The identity rules used to decide whether two Library items refer to the same saved content. YouTube Music can expose the same playlist as either a `VL...` browse ID or a raw playlist ID, and the same followed artist as either an `MPLAUC...` library browse ID or a public `UC...` channel ID. Kaset treats those equivalent forms as one Library item.

## Library Content Parsing

The parser slice that turns YouTube Music Library browse responses into Kaset Library content. It owns Library renderer traversal and item classification before handing identity equivalence to Library Content Identity.

## Library Content Reconciliation

The rules that merge optimistic local Library mutations with eventually-consistent YouTube Music Library snapshots. Kaset keeps locally added items visible and locally removed items suppressed until backend responses stabilize.

## Library Mutation Orchestration

The workflows that apply a user-requested Library change to YouTube Music, invalidate stale Library response caches, update visible Library state optimistically, and schedule reconciliation when backend snapshots lag behind the accepted mutation.

## Queue Song Metadata

The rules for preparing songs before they enter Kaset's native queue. This includes stripping generic YouTube Music album labels from artist metadata, applying fallback artist/album/thumbnail values for album-derived queue actions, and preserving playback metadata while rebuilding song values.

## Album Playback Actions

The workflows that fetch album tracks from YouTube Music playlist details, prepare them as queue-ready songs, and either insert them into the queue or replace playback with the album.

## Album Library Identity

The two identifiers required for album Library behavior. An `MPRE...` browse ID identifies the album detail page and the visible saved album, while an `OLAK...` playlist ID is the target sent to YouTube Music's add/remove Library mutation endpoints.

## Playlist Playback Actions

The workflows that turn playlist browse data into native playback queues. This includes radio playlist queue fallback, browse playability correction, playlist artwork fallback, continuation loading, duplicate filtering, and discarding continuations when the active queue has changed.

## YouTube Ask

The watch-page Ask Gemini capability in the regular YouTube experience. Kaset supports server-issued suggestion chips plus revision-bound free-text turns using the validated composer command. It uses YouTube APIs rather than the playback WebView, selects the fixed WEB request profile explicitly in production, and appears only when YouTube returns an eligible bootstrap for a signed-in primary account.

## Ask Bootstrap

The eligible YouChat material discovered in the current video's watch-page `next` response. A bootstrap may expose suggestions and the revision-bound free-text capability directly, or carry the opaque command needed to prepare the prompt-free initial Ask panel. Initial panel materialization may supply a missing free-text capability. The bootstrap and anything materialized from it are valid only for the video, authentication generation, and primary-account scope that produced them.

## Ask Conversation

The memory-only visible transcript, revision-bound free-text capability, and server-issued follow-up suggestions for one watch-scoped Ask chat. New Chat replaces it only after a fresh bootstrap and panel preparation succeed. Navigation, account/authentication changes, cancellation, or app termination discard it.

## Server-Issued Ask Suggestion

A sanitized visible chip label paired internally with an opaque server command. The label is displayed verbatim and is not a localized Kaset string. Selecting the suggestion replays its exact command; Kaset never turns the label into free-form input.


## Server-Issued Ask Free-Text Command

The opaque `sendUserQueryCommand` found either in the canonical eligible watch-page `next` panel—currently under its footer `chatInputViewModel` or an eligible YouChat item—or in its prompt-free initial `get_panel` materialization. Kaset uses the `next` command when present; otherwise it may materialize the exact server-issued panel continuation and accept only a confirmed command from that response. Each bound conversation revision may consume the command once with the validated `get_panel` form fields and current playback offset. A successful response advances the revision and keeps the command available unless YouTube supplies a replacement; uncertain failures discard it and require New Chat. Its continuation and click-tracking values remain in memory and are never printed or persisted.

## Opaque Ask Command

Unprintable, non-persistent server state used only to continue the current Ask conversation. It must never be logged, cached, serialized, restored, placed in fixtures, exposed through accessibility identifiers, or reused across a video, account, conversation, or revision boundary.

## Ask Request Profile

The bounded YouTube WEB client configuration used only for Ask compatibility. A profile is selectable for production only after the read-only parity workflow confirms signed-in eligibility and initial panel preparation. An HTTP 200 response that contains signed-out state is a failed profile.
