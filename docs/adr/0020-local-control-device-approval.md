# ADR-0020: Secure Local Control Device Approval & PIN Verification

## Status
Accepted

## Context
Kaset previously had a local HTTP control server (`LocalControlServer`) that allowed simple playback control, but it operated either without authentication or used a single global access token. Exposing a global token over the local network is insecure and cumbersome for users who want to connect secondary devices (like mobile phones or tablets) to control media playback on their Mac. There was a need for a secure, user-friendly registration and approval flow:
- A device should be able to scan a QR code on the Mac's screen to open the controller.
- The user should be prompted to input a 4-to-6 digit PIN to request connection.
- The host Mac must show a queue of pending devices to Approve or Deny.
- Approved devices must receive a unique device-specific session token, with the ability for the host to revoke access at any time.
- All implementations must be 100% native (no external Node/Python services, no new third-party dependencies).

We implemented a secure, local-first registration and approval flow supporting two connection methods:
1. **`RemoteDeviceManager`**: A new MainActor-isolated service managing approved and pending devices. It stores `RemoteDevice` and `PendingApproval` lists, persisting them in `UserDefaults` via standard JSON encoding.
2. **Enhanced `LocalControlServer`**:
   - Added `/check` (auto-login check) and `/request_approval` (PIN verification request) endpoints.
   - Bypassed general authentication check for these registration endpoints and the main remote web interface HTML page.
   - Support dual connection modes:
     - **Direct PIN Login**: If the client provides the correct PIN via `/request_approval`, the server directly creates an approved device entry, issues a session token, and returns it immediately to log the device in.
     - **Request Host Access**: A client can request access without entering a PIN. This registers the device as `pending` in the host's approval queue. The host Mac can then approve or deny the request from settings.
   - Upgraded the served controller HTML with a client-side state machine using `localStorage` for device UUID, handling the PIN login, direct request-host-access actions, and pending state polling loops.
3. **Static URLs & QR Codes**:
   - Discovered LAN URLs and generated QR codes are completely static (e.g. `http://<computer-name>.local:<PORT>/`) with no tokens exposed in the query string.
   - Friendly Bonjour names like `kaset.local` were removed from URLs to focus on the reliable system local hostname.
4. **GeneralSettingsView Integration**: Integrated controls to toggle the server, view the global security PIN, view active LAN URLs, scan QR codes, and manage the pending/approved device lists (Approve/Deny/Revoke buttons).

## Consequences
- **Security**: The global token is completely removed. Client session tokens are never exposed in URL history or query logs; they are generated on successful PIN verification and stored in the browser's `localStorage`. Denied or revoked devices are immediately blocked from hitting control endpoints.
- **Convenience**: Users can pair their devices in seconds via QR code scans and a simple PIN entry.
- **Portability**: Keep dependencies at zero; the implementation uses built-in Apple frameworks (`Network`, `CoreImage`, `SwiftUI`, `Foundation`).
- **Network Permissions**: Packaged sandboxed builds require the `com.apple.security.network.server` entitlement enabled in `Kaset.entitlements` to allow local port binding.
