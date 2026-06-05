# ADR-0020: Now Playing Surfaces

## Status

Accepted

## Context

Kaset had multiple emerging auxiliary playback surfaces that needed the same
inputs and controls:

- Native notch-style UI such as Music Island.
- Local bridge integrations such as Boring Notch.
- Future menu bar widgets or other now-playing surfaces.

Without a shared layer, each surface would independently observe
`PlayerService`, fetch lyrics through `SyncedLyricsService`, start and stop
high-frequency WebView lyric polling, add settings booleans, and route
playback commands. That duplicates fragile logic and makes it easy for one
surface to stop polling while another synced-lyrics surface is still visible.

Existing ADRs also constrain the design:

- ADR-0012 keeps synced lyric resolution centralized and only pays the
  high-frequency polling cost while synced lyrics are active.
- ADR-0014 keeps third-party integration behavior user-managed and opt-in.

## Decision

Introduce a generic **Now Playing Surfaces** layer. The layer defines one
canonical read model, one command-routing boundary, and a narrow adapter
interface for concrete surfaces.

### Read Model

`NowPlayingSnapshot` is the canonical snapshot consumed by auxiliary
surfaces. It contains playback state, current track metadata, artwork, video
ID, progress, duration, volume, shuffle/repeat state, like state, and the
current synced lyric line when available.

`NowPlayingSnapshotStore` derives snapshots from `PlayerService` and
`SyncedLyricsService`. This is the only new now-playing surface type that
knows about those concrete services.

### Command Routing

`NowPlayingCommandRouting` accepts typed commands such as play, pause,
seek, volume, next/previous, like/dislike, shuffle, and repeat.
`PlayerNowPlayingCommandRouter` maps those commands to
`PlayerServiceProtocol`.

Concrete surfaces send commands through this router instead of depending on
`PlayerService` directly.

### Surface Adapters

Concrete integrations implement `NowPlayingSurfaceAdapter`:

```swift
@MainActor
protocol NowPlayingSurfaceAdapter: AnyObject {
    var descriptor: NowPlayingSurfaceDescriptor { get }

    func start(context: NowPlayingSurfaceContext) async
    func stop() async
}
```

The context provides only snapshots, command routing, and a main-window
opening callback. Adapters do not receive `PlayerService`,
`SyncedLyricsService`, `SingletonPlayerWebView`, or `SettingsManager`.

### Lyrics Demand

`LyricsDemandCoordinator` owns synced-lyrics demand across all consumers.
It reference-counts demand by consumer ID and only starts WebView
high-frequency polling when at least one active consumer needs synced lyrics.
Polling stops only after the last active consumer releases demand.

This protects cases where the main lyrics sidebar, mini-player lyrics, and
Music Island are visible at the same time.

### Settings

Settings store enabled surfaces generically as
`SettingsManager.enabledNowPlayingSurfaces: Set<NowPlayingSurfaceID>`.
Surface-specific booleans are intentionally avoided.

### Boring Notch Compatibility

Boring Notch support is implemented as:

```text
LocalNowPlayingBridgeAdapter
  -> BoringNotchCodec
```

The adapter owns the local HTTP/WebSocket server. The codec owns the
Boring Notch-compatible JSON payloads and route-to-command translation.
The bridge is user-managed through the generic surface setting and rejects
non-loopback clients before exposing its local auth token or playback
commands.

Because browser-originated requests can target loopback services, token
issuance also has two local trust checks:

- The `Host` header must be `localhost`, `127.0.0.1`, or `[::1]` (with an
  optional port) to reject DNS-rebinding style hosts.
- If an `Origin` header is present, it must also point at `localhost`,
  `127.0.0.1`, or `[::1]`. Native companion clients that do not send an
  origin are still accepted.
- The first `/auth/boringNotch` request for a bridge session must be approved
  through a native confirmation prompt. The approval is remembered until the
  bridge stops.

The bridge intentionally keeps Boring Notch's token-based compatibility shape,
but does not silently grant that token to every local HTTP caller.

## Consequences

### Positive

- Auxiliary playback surfaces share one snapshot model and one command
  router.
- Notch UI and bridge integrations no longer duplicate lyrics fetching,
  polling lifecycle, or playback snapshot construction.
- New surfaces can be added by implementing a small adapter and descriptor.
- Synced lyric polling is coordinated centrally and remains active until all
  lyric consumers disappear.
- Third-party bridge support remains opt-in and isolated from core playback
  state.

### Negative

- The snapshot store currently polls at a short interval because progress
  and synced lyric time are continuous values.
- The local bridge still maintains a hand-written HTTP/WebSocket compatibility
  server, which requires careful testing when Boring Notch changes its API.
- CORS remains permissive for compatibility with local companion clients, so
  Host/Origin validation plus user approval are the primary defenses against
  unexpected browser-originated localhost requests.
- The HTTP and WebSocket frame parsers are intentionally small and covered by
  byte-level unit tests for partial HTTP bodies, pipelined HTTP requests,
  masked WebSocket frames, and extended WebSocket payload lengths.

### Neutral

- `NowPlayingManager` continues to handle system media key integration.
- The WebView remains the playback engine; this ADR only changes auxiliary
  now-playing surfaces around it.
