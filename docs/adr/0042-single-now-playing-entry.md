# ADR-0042: Single Now Playing entry

## Status

Accepted

## Context

Music plays in a `WKWebView` (ADR-0001), and WebKit publishes its own Now Playing card for the
page: artwork, artist and album, and the page's media-session actions. Since #387, Kaset also
publishes a small tagged entry (title and artist) through `MPNowPlayingInfoCenter`, so the Play key
resumes Kaset instead of Apple Music while music is paused.

The handoff assumed WebKit's card replaces the app's metadata. It does not: WebKit's card is a
separate Now Playing entry. Kaset's entry stayed alongside it, marked as playing during playback,
so Control Center showed Kaset twice (#457).

Measured on macOS 27 with a trace of remote commands, Now Playing decisions, page media-session
actions and observed page state:

- Kaset's own entry is a media-key target only while it is the most recently playing one. Keeping
  it marked as playing during playback is what routed media keys to Kaset, which is also what made
  it a visible duplicate.
- With Kaset's entry withdrawn, media keys go to WebKit's card. A pause from the card or a media key
  works, but after an in-app pause the page's playback suppression (`__kasetPlaybackSuppressed`)
  cancels the card's play, so Play did nothing.
- An entry with playback state but no metadata does not appear in Control Center, and it keeps
  Kaset's own player a media-key target after a pause.
- On a signed-in cold launch where the page restored a track, WebKit's card for the music page was
  in Control Center before anything had played, next to Kaset's tagged entry. The Play key went to
  Apple Music whether or not Kaset published that entry, as #387 already noted.
- While a YouTube video played, Control Center showed the music page's card and Kaset's tagged video
  entry, but no WebKit card for the watch page. Media keys reached the video through Kaset's own
  player.

## Decision

- WebKit's play and pause media-session actions are Kaset-owned, like next and previous: the
  document-start wrapper keeps YouTube from registering them, and the override script installs
  handlers that post `REMOTE_PLAY` and `REMOTE_PAUSE`. These go through the same native transport
  queue as media keys, so a play after an in-app pause clears Kaset's pause intent.
- For music, Kaset publishes playback state only (no metadata), including before the first play.
  Whenever the music page has a track loaded, WebKit's card is the single Kaset entry, and Kaset's
  own player stays a media-key target. A loading track keeps an existing entry without publishing
  a new one.
- YouTube video keeps its tagged minimal entry, which is the video's only entry.

## Consequences

### Positive

- One Kaset entry in Control Center for music whenever the page has a track loaded, playing or
  paused, including before the first play.
- Play and pause on WebKit's card, media keys and Kaset's own controls all go through the native
  player, whichever entry macOS routes the key to.

### Negative

- While a video plays with a music track loaded, Control Center still shows two Kaset entries: the
  video's entry and the music page's card.
- The music page no longer runs YouTube's own play/pause handlers; Kaset's native resume and pause
  drive the page instead.
- When the music page has no track loaded while Kaset has one (a signed-out launch that defers the
  restored track, or a page that restores no track), Control Center shows no Kaset entry until
  playback starts, where the tagged entry used to offer a play button. The Play key goes to Apple
  Music either way.
- The cold-launch behavior was measured on macOS 27. If WebKit shows no card before the first play
  on an older macOS, a cold launch there also shows no Kaset entry until playback starts.
