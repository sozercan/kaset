# ADR-0036: Music audio output continuity

## Status

Accepted

## Context

YouTube Music can advance the media clock from zero while the beginning of a
track is absent from the app's audio output. Digital captures of Weval's
"Silence on the Wall" into "Look Around" reproduced this both in Kaset and in
a plain playback WebView. Keeping a silent Web Audio output active across the
transition recovered the opening transient without seeking or restarting media.

This is separate from the delay between tracks. The native queue described in
[ADR-0035](0035-gapless-playback-native-queue.md) still depends on YouTube Music
buffering and WebKit playback timing.

## Decision

The music playback document owns a small `AudioContext` with an oscillator
connected through a gain of zero. It starts for intended playback and stays
active across short natural transitions. It never receives the media element's
audio, changes its volume, or replaces the DRM playback path.

Explicit Pause, Stop, deferred playback, media errors, page exit, and wireless
playback release the local output. Startup and track-end waits release it after
five seconds unless media starts playing. Events from replaced media elements
cannot change the active output. Failure to create or resume the context leaves
ordinary playback available.

## Consequences

The output stays active during music playback and briefly between tracks. This
adds a silent audio graph but avoids keeping it running through an idle or
paused session. AirPlay continues to use the media element's own output route.

Captured openings improved, but this does not promise sample-perfect playback
or remove the interval between tracks. Playback captures validate the app's
digital output; physical speakers and other output devices require separate
listening checks.
