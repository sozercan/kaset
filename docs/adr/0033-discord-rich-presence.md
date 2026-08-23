# ADR-0033: Discord Rich Presence Integration

## Status

Accepted

## Context

Kaset plays YouTube Music songs/podcasts and regular YouTube videos natively. Users want their active listening/watching status reflected on Discord Rich Presence with rich details (track title, artist, album, elapsed/remaining duration, high-resolution artwork, and a "Listen in Kaset / YouTube" action button).

Key design challenges and constraints:
1. **Zero Secrets in App Binary** — Under no circumstances may client secrets, bot tokens, or private keys be baked into the macOS app binary.
2. **App Sandbox Compliance** — Kaset is a sandboxed macOS application (`com.apple.security.app-sandbox`). Connecting to Discord desktop's local Unix domain socket (`$TMPDIR/discord-ipc-0` through `discord-ipc-9`) must operate reliably without violating sandbox constraints.
3. **Local Desktop IPC** — Directly connects via Unix Domain Sockets to the local Discord desktop client (`$TMPDIR/discord-ipc-0` through `discord-ipc-9`), requiring zero hosting infrastructure, proxy servers, or user logins.
4. **Granular Privacy Toggles** — Users have differing privacy preferences; they must have individual toggles in Settings for track title, artist, album, timestamps, artwork, action button, and independent toggles for Music vs. Video contexts.
5. **Robust Lifecycle & Auto-Reconnect** — The connection must automatically attempt reconnection up to 5 times with exponential backoff before transitioning to a manual "Connect" action state. Paused playback immediately clears Rich Presence.
6. **No Third-Party Frameworks** — The entire IPC protocol, framing, handshake, serialization, and lifecycle is implemented in clean-room, native Swift concurrency and POSIX Unix domain sockets.

## Decision

### 1. Transport Architecture (`DiscordPresenceServiceProtocol`)

Define `DiscordPresenceServiceProtocol` as the public interface for Discord presence backends, integrated into `DiscordPresenceCoordinator`:

- `DiscordLocalIPCService`: Communicates with the local Discord client via Unix Domain Sockets (`discord-ipc-0`..`discord-ipc-9`). Performs standard opcode handshake (`HANDSHAKE` opcode 0 with client ID `1541148589269454989`, `FRAME` opcode 1 for `SET_ACTIVITY`).
- `DiscordPresenceCoordinator`: An `@MainActor @Observable` service that monitors `PlayerService` (music) and `YouTubePlayerService` (video), checks privacy settings, prepares presence payloads, and synchronizes status with the IPC transport.

### 2. POSIX IPC & Socket Resolution

To connect to Discord's local Unix Domain Socket:
- Discovers socket nodes across Darwin user temporary directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), `$TMPDIR`, `/tmp`, and `/private/tmp`.
- Connects using standard POSIX `socket(AF_UNIX, SOCK_STREAM, 0)` and framing protocol.
- When Discord is closed or unreachable, socket operations fail gracefully with non-blocking error handling and enter the exponential backoff state machine without app disruption.

### 3. Presence Payload & Privacy Filtering

When music or video plays, `DiscordPresenceCoordinator` constructs an activity payload:
- **Type**: `Listening` (type 2) for YouTube Music, `Watching` (type 3) for YouTube video.
- **Details**: Track title (if enabled).
- **State**: Artist name and Album name (if enabled).
- **Timestamps**: Playback start and expected end timestamp (if enabled).
- **Assets**: Large image set to track thumbnail URL (or Kaset default asset key) with album name tooltip; small image set to Kaset app icon with tooltip.
- **Buttons**: Optional "Listen / Watch" URL button pointing to the YouTube Music / YouTube URL (if enabled).
- **Suppression**: Paused playback clears presence; disabling the active context (Music/Video) instantly suppresses presence.

### 4. Exponential Backoff & Connection Lifecycle

- **Automatic Reconnect**: When connection is lost or Discord starts after Kaset, the coordinator retries with exponential backoff (1s, 2s, 4s, 8s, 16s) up to 5 attempts.
- **Manual Fallback**: After 5 failed attempts, state transitions to `.disconnected(error)` or `.idle` and reveals a manual "Connect" button in Settings.
- **Reset**: Any track play or manual settings toggle resets the attempt counter and re-triggers connection.

### 5. Settings & UI Integration

Add a dedicated **Discord** tab in `SettingsView` (`DiscordSettingsView`) containing:
- Master enable toggle with description note stating Discord desktop app must be installed and running locally.
- Live Connection Status indicator (Connected, Connecting with retry counter, Disconnected, Error) and manual Connect/Disconnect button.
- Context toggles (YouTube Music listening status, YouTube Video watching status).
- Granular privacy toggles: Show Song Title, Show Artist, Show Album, Show Elapsed/Remaining Time, Show Album Artwork, Show Listen Button.

## Consequences

### Positive
- **Zero Secrets & Zero Hosting Costs**: No backend servers, workers, or client secrets required.
- **Instant Connection**: No OAuth logins needed; presence connects seamlessly to the running Discord client.
- **Privacy-First**: Users control exactly what metadata reaches Discord.
- **Zero Dependencies**: Pure native Swift implementation matching repository standards.
- **Resilient**: Graceful degradation when Discord is not running.

### Negative
- **IPC Socket path variations**: Discord on macOS may create sockets in `/var/folders/.../T/` ($TMPDIR) or `/tmp/`; the socket resolver must probe both locations.
