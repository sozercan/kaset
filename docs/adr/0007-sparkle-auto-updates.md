# ADR-0007: Sparkle Auto-Updates

## Status

Accepted

## Context

Kaset is distributed outside the Mac App Store via GitHub Releases and Homebrew Cask. Users need a reliable way to receive updates without manually downloading new versions. The lack of automatic updates creates friction for users and delays security fixes and feature rollouts.

Requirements:
- **Non-App Store distribution**: App Store's built-in update mechanism is not available
- **User trust**: Updates must be cryptographically signed to prevent tampering
- **Seamless UX**: Updates should happen with minimal user intervention
- **macOS native**: The solution should follow Apple's design patterns
- **Sandbox compatible**: Must work with macOS app sandboxing

## Decision

We integrate [Sparkle 2.x](https://sparkle-project.org/) for automatic update checks and installation.

### Key Design Choices

1. **Sparkle 2.x via Swift Package Manager**
   - Modern Swift-compatible API
   - Supports sandboxed apps via XPC services
   - EdDSA (Ed25519) signatures for security
   - Automatic delta updates for bandwidth efficiency

2. **Appcast hosted on GitHub**
   - `appcast.xml` in repository root
   - Served via GitHub raw content
   - Updated by CI on each release

3. **EdDSA code signing**
   - Private key stored in GitHub Secrets
   - Public key embedded in app bundle
   - Signatures verified before installation

4. **User preferences**
   - Toggle for automatic checks (default: enabled)
   - Manual "Check for Updates..." menu item
   - Settings UI showing last check date

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        KasetApp                              │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │  UpdaterService │───▶│ SPUStandardUpdaterController   │  │
│  │  (@Observable)  │    │        (Sparkle)               │  │
│  └────────┬────────┘    └───────────────┬────────────────┘  │
│           │                             │                    │
│           ▼                             ▼                    │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │GeneralSettings  │    │    Sparkle Update UI           │  │
│  │  View (Toggle)  │    │  (Download/Install dialogs)    │  │
│  └─────────────────┘    └────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │   GitHub (appcast.xml)        │
              │   https://raw.githubusercontent│
              │   .com/sozercan/kaset/main/   │
              │   appcast.xml                 │
              └───────────────────────────────┘
```

### Update Flow

1. **On app launch** (if automatic checks enabled):
   - Sparkle fetches `appcast.xml` from GitHub
   - Compares version against current app version
   - If newer version exists, shows update dialog

2. **User clicks "Install Update"**:
   - Sparkle downloads the DMG from GitHub Releases
   - Verifies EdDSA signature
   - Extracts and replaces app bundle
   - Relaunches the app

3. **Manual check** (Kaset → Check for Updates...):
   - Same flow but user-initiated
   - Shows "You're up to date" if no update available

### Release Process

1. Tag new version: `git tag v1.2.3`
2. CI builds, archives, and creates DMG
3. CI signs DMG with EdDSA key
4. CI updates `appcast.xml` with new entry
5. CI uploads DMG to GitHub Releases
6. Users receive update on next check

## Consequences

### Positive

- **Seamless updates**: Users receive updates automatically without visiting GitHub
- **Security**: EdDSA signatures prevent malicious update injection
- **Standard UX**: Sparkle is the de facto standard for macOS app updates
- **Delta updates**: Sparkle can generate deltas to reduce download size
- **Rollback support**: Users can skip versions if needed
- **No infrastructure cost**: Hosted entirely on GitHub

### Negative

- **Framework dependency**: Adds ~2MB to app size (Sparkle.framework)
- **Key management**: EdDSA private key must be secured in CI secrets
- **Manual appcast updates**: Initial setup requires manual appcast management
- **Sandbox complexity**: May require XPC entitlements for sandboxed installation

### Neutral

- **Info.plist configuration**: Requires `SUFeedURL`, `SUPublicEDKey` entries
- **Homebrew Cask**: Users installing via Cask may see duplicate update prompts

## Implementation Notes

### Required Info.plist Keys

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/sozercan/kaset/main/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>YOUR_BASE64_ENCODED_PUBLIC_KEY</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

### Key Generation

```bash
# Generate EdDSA keypair (run once, store private key securely)
./DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

### Signing a Release

```bash
./Tools/sign-update.sh ./build/Kaset-v1.2.3.dmg
```

## References

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle GitHub Repository](https://github.com/sparkle-project/Sparkle)
- [Apple Code Signing Guide](https://developer.apple.com/documentation/security/code_signing_services)
