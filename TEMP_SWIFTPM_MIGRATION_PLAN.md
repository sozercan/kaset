# SwiftPM Migration Plan: Kaset

> **Status**: Planning  
> **Created**: January 3, 2026  
> **Goal**: Migrate from Xcode project to pure SwiftPM build system

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current State Analysis](#current-state-analysis)
3. [Target State](#target-state)
4. [Migration Phases](#migration-phases)
5. [Directory Restructure](#directory-restructure)
6. [Package.swift Design](#packageswift-design)
7. [Packaging Scripts](#packaging-scripts)
8. [Build Configurations](#build-configurations)
9. [Resource Handling](#resource-handling)
10. [Testing Strategy](#testing-strategy)
11. [Signing & Notarization](#signing--notarization)
12. [CI/CD Considerations](#cicd-considerations)
13. [Risk Assessment](#risk-assessment)
14. [Rollback Strategy](#rollback-strategy)
15. [Success Criteria](#success-criteria)
16. [References](#references)

---

## Executive Summary

### Why Migrate?

| Benefit | Description |
|---------|-------------|
| **Reproducible builds** | No Xcode project file conflicts, deterministic resolution |
| **Better CI/CD** | `swift build` works headlessly, no `xcodebuild` quirks |
| **Conditional compilation** | SwiftPM's `.define()` for debug/release flags |
| **Modular architecture** | Easier to split into libraries/frameworks |
| **Cross-IDE support** | Works with VS Code, Cursor, any LSP-aware editor |
| **Version control friendly** | `Package.swift` + `Package.resolved` vs opaque `.pbxproj` |

### Trade-offs

| Challenge | Mitigation |
|-----------|------------|
| Manual app bundling | Shell scripts (proven pattern from CodexBar) |
| UI tests | Keep minimal `.xcodeproj` or migrate to XCTest launch |
| Asset catalogs | Script-based compilation with `actool` |
| Entitlements | Applied via `codesign` in packaging script |
| Learning curve | Document everything, reference CodexBar patterns |

---

## Current State Analysis

### Xcode Project Structure

```
Kaset.xcodeproj/
├── project.pbxproj          # 1453 lines, manages all targets
└── project.xcworkspace/
```

### Targets

| Target | Type | Purpose |
|--------|------|---------|
| `Kaset` | Application | Main app bundle |
| `KasetTests` | Unit Test Bundle | Swift Testing + XCTest |
| `KasetUITests` | UI Test Bundle | XCUITest automation |

### Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| Sparkle | 2.8.1+ | Auto-updates |

### Build Settings

| Setting | Debug | Release |
|---------|-------|---------|
| macOS Target | 26.0 | 26.0 |
| Swift Version | 6.0 | 6.0 |
| Sandbox | ❌ (false) | ✅ (true) |
| JIT Entitlement | ✅ | ✅ |
| Code Sign Style | Automatic | Automatic |

### Resources

| Resource | Location | Notes |
|----------|----------|-------|
| Assets.xcassets | `App/Assets.xcassets/` | AccentColor only |
| App Icon | `App/kaset.icon/` | macOS 14+ icon bundle format |
| Info.plist | `App/Info.plist` | URL schemes, Sparkle config |
| Entitlements (Debug) | `App/Kaset.Debug.entitlements` | Non-sandboxed |
| Entitlements (Release) | `App/Kaset.entitlements` | Sandboxed |

### Source File Count

```
App/           ~5 files   (AppDelegate, KasetApp, etc.)
Core/          ~60 files  (Models, Services, ViewModels, Utilities)
Views/macOS/   ~40 files  (SwiftUI views)
Tests/         ~40 files  (Unit + UI tests)
Tools/         1 file     (api-explorer.swift)
```

---

## Target State

### New Directory Structure

```
Kaset/
├── Package.swift
├── Package.resolved
├── Sources/
│   ├── Kaset/                    # Main app target
│   │   ├── App/
│   │   ├── Core/
│   │   ├── Views/
│   │   └── Resources/
│   └── KasetCLI/                 # Optional: CLI tools target
│       └── APIExplorer/
├── Tests/
│   ├── KasetTests/               # Unit tests
│   └── KasetUITests/             # UI tests (special handling)
├── Scripts/
│   ├── package_app.sh            # App bundle assembly
│   ├── compile_and_run.sh        # Dev loop
│   ├── sign-and-notarize.sh      # Release signing
│   └── build_icon.sh             # Icon conversion
├── Resources/
│   ├── Info.plist.template       # Template for variable substitution
│   ├── Kaset.entitlements
│   ├── Kaset.Debug.entitlements
│   ├── Assets.xcassets/
│   └── kaset.icon/
├── Kaset.xcodeproj/              # KEEP: For UI tests only (minimal)
└── version.env                   # Version variables for scripts
```

### Build Commands (Target State)

```bash
# Development
swift build                           # Debug build
swift test                            # Run unit tests
./Scripts/compile_and_run.sh          # Full dev loop

# Release
swift build -c release                # Release build
./Scripts/package_app.sh release      # Package .app
./Scripts/sign-and-notarize.sh        # Sign + notarize
```

---

## Migration Phases

### Phase 0: Preparation (Pre-Migration)

#### 0.1 Create Migration Branch
```bash
git checkout -b feature/swiftpm-migration
```

#### 0.2 Document Current Build Output
- [ ] Record current build times with Xcode
- [ ] Document all build warnings
- [ ] Capture current app bundle structure
- [ ] List all Info.plist keys in final bundle
- [ ] Export current code signing settings

#### 0.3 Study CodexBar Implementation
- [ ] Review `Scripts/package_app.sh` structure
- [ ] Understand entitlements injection
- [ ] Study Info.plist generation
- [ ] Note Sparkle integration patterns

**Exit Criteria**: Complete understanding of current build, reference material ready

---

### Phase 1: Create Package.swift (Parallel to Xcode)

#### 1.1 Initial Package.swift
- [ ] Create `Package.swift` with correct platforms and Swift version
- [ ] Add Sparkle dependency
- [ ] Configure main executable target
- [ ] Add test target

#### 1.2 Directory Restructure (Sources/)
- [ ] Create `Sources/Kaset/` directory
- [ ] Move `App/` → `Sources/Kaset/App/`
- [ ] Move `Core/` → `Sources/Kaset/Core/`
- [ ] Move `Views/macOS/` → `Sources/Kaset/Views/`
- [ ] Update any relative import paths

#### 1.3 Verify Compilation
```bash
swift build 2>&1 | tee build.log
```
- [ ] Fix any missing imports
- [ ] Resolve module visibility issues
- [ ] Address any platform availability issues

#### 1.4 Parallel Testing
- [ ] Ensure `xcodebuild` still works (xcodeproj references updated paths)
- [ ] Ensure `swift build` works
- [ ] Compare binary output

**Exit Criteria**: Both `xcodebuild` and `swift build` compile successfully

---

### Phase 2: Resource Handling

#### 2.1 Asset Catalog Compilation
- [ ] Create script to compile `.xcassets` using `actool`:
  ```bash
  xcrun actool Assets.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0
  ```

#### 2.2 Icon Conversion
- [ ] Create `Scripts/build_icon.sh`:
  ```bash
  # Convert .icon bundle to .icns
  iconutil --convert icns --output Icon.icns kaset.icon
  ```

#### 2.3 Info.plist Generation
- [ ] Create `Resources/Info.plist.template` with placeholders:
  ```xml
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key>
  <string>${MARKETING_VERSION}</string>
  ```
- [ ] Script substitutes variables at build time

#### 2.4 Create version.env
```bash
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.sertacozercan.Kaset
```

**Exit Criteria**: All resources compile and bundle correctly via scripts

---

### Phase 3: Packaging Script

#### 3.1 Core package_app.sh Structure
```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Parse arguments (debug/release)
# 2. Source version.env
# 3. Build with swift build
# 4. Create .app bundle structure
# 5. Copy binary
# 6. Compile and copy resources
# 7. Generate Info.plist
# 8. Copy entitlements
# 9. Copy frameworks (Sparkle)
# 10. Code sign
# 11. Verify bundle
```

#### 3.2 Bundle Structure Creation
```
Kaset.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── Kaset              # Binary
│   ├── Resources/
│   │   ├── Assets.car         # Compiled assets
│   │   ├── AppIcon.icns       # App icon
│   │   └── *.lproj/           # Localizations (future)
│   ├── Frameworks/
│   │   └── Sparkle.framework
│   └── _CodeSignature/
```

#### 3.3 Sparkle Framework Embedding
- [ ] Locate Sparkle in `.build/` artifacts
- [ ] Copy to `Contents/Frameworks/`
- [ ] Set correct `@rpath` via `install_name_tool`
- [ ] Sign framework separately before app signing

#### 3.4 Entitlements Application
```bash
ENTITLEMENTS="Resources/Kaset.entitlements"
if [[ "$CONFIG" == "debug" ]]; then
  ENTITLEMENTS="Resources/Kaset.Debug.entitlements"
fi
codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  "Kaset.app"
```

**Exit Criteria**: `package_app.sh` produces runnable, signed `.app`

---

### Phase 4: Dev Loop Script

#### 4.1 compile_and_run.sh Structure
```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Kill existing Kaset instances
pkill -x Kaset || true

# 2. Run swift test
swift test

# 3. Package app
./Scripts/package_app.sh debug

# 4. Launch app
open -n Kaset.app

# 5. Verify app stays running
sleep 2
pgrep -x Kaset || { echo "App crashed"; exit 1; }

echo "✅ Dev loop complete"
```

#### 4.2 Watch Mode (Optional)
- [ ] Consider `fswatch` or similar for auto-rebuild
- [ ] Hot reload considerations

**Exit Criteria**: Single command rebuilds and relaunches app

---

### Phase 5: Testing Migration

#### 5.1 Unit Tests with Swift Testing
- [ ] Verify `swift test` runs all unit tests
- [ ] Ensure Swift Testing macros work (`@Test`, `@Suite`)
- [ ] Check test discovery works correctly
- [ ] Verify performance tests (`measure {}`)

#### 5.2 UI Tests Strategy

**Option A: Keep Minimal xcodeproj**
- Strip xcodeproj to only contain UI test target
- UI tests reference built app bundle
- Run via: `xcodebuild test -only-testing:KasetUITests`

**Option B: XCTest Launch Approach**
- Create standalone test binary
- Launch app from test process
- More complex but fully SwiftPM

**Recommendation**: Option A (pragmatic, proven)

#### 5.3 Test Commands (Final)
```bash
# Unit tests
swift test

# UI tests (requires xcodeproj)
xcodebuild test -scheme KasetUITests \
  -destination 'platform=macOS' \
  TEST_HOST="$(pwd)/Kaset.app/Contents/MacOS/Kaset"
```

**Exit Criteria**: All tests pass via new build system

---

### Phase 6: Signing & Notarization

#### 6.1 sign-and-notarize.sh
```bash
#!/usr/bin/env bash
set -euo pipefail

APP="Kaset.app"
ZIP="Kaset-${MARKETING_VERSION}.zip"
IDENTITY="Developer ID Application: Your Name"
NOTARY_PROFILE="kaset-notary"

# 1. Package release build
./Scripts/package_app.sh release

# 2. Sign with hardened runtime
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements Resources/Kaset.entitlements \
  --deep "$APP"

# 3. Verify signature
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"

# 4. Create zip for notarization
ditto -c -k --keepParent "$APP" "$ZIP"

# 5. Submit for notarization
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# 6. Staple ticket
xcrun stapler staple "$APP"

# 7. Re-zip with stapled ticket
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✅ Signed and notarized: $ZIP"
```

#### 6.2 Keychain Profile Setup
```bash
xcrun notarytool store-credentials "kaset-notary" \
  --apple-id "your@email.com" \
  --team-id "TEAMID" \
  --password "@keychain:AC_PASSWORD"
```

**Exit Criteria**: Notarized zip passes Gatekeeper on fresh Mac

---

### Phase 7: CI/CD Updates

#### 7.1 GitHub Actions Workflow
```yaml
name: Build & Test

on: [push, pull_request]

jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
      
      - name: Build
        run: swift build -c release
      
      - name: Test
        run: swift test
      
      - name: Package
        run: ./Scripts/package_app.sh release
      
      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: Kaset.app
          path: Kaset.app
```

#### 7.2 Release Workflow
```yaml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      
      - name: Import Certificates
        # ... certificate import steps
      
      - name: Build & Sign
        run: ./Scripts/sign-and-notarize.sh
      
      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: Kaset-*.zip
```

**Exit Criteria**: CI builds and tests pass, releases are automated

---

### Phase 8: Cleanup & Documentation

#### 8.1 Remove Obsolete Files
- [ ] Delete old xcodeproj (if UI tests migrated)
- [ ] Or strip to minimal UI test project
- [ ] Remove any Xcode-specific build artifacts from gitignore

#### 8.2 Update Documentation
- [ ] Update AGENTS.md with new build commands
- [ ] Update README.md with build instructions
- [ ] Create docs/building.md with detailed steps
- [ ] Update CONTRIBUTING.md

#### 8.3 Update .gitignore
```gitignore
# SwiftPM
.build/
.swiftpm/
Package.resolved  # Or track it, depending on preference

# Build artifacts
Kaset.app/
*.zip
*.dmg
```

**Exit Criteria**: Clean repo, updated docs, no obsolete files

---

## Package.swift Design

### Complete Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kaset",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Kaset", targets: ["Kaset"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "Kaset",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Kaset",
            exclude: [
                "Resources/Info.plist.template",
            ],
            resources: [
                // Note: Assets compiled separately via actool
            ],
            swiftSettings: [
                // Conditional compilation flags
                .define("DEBUG", .when(configuration: .debug)),
                .define("VERBOSE_LOGGING", .when(configuration: .debug)),
                
                // Swift 6 strict concurrency
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        
        // Optional: CLI tools target
        .executableTarget(
            name: "KasetCLI",
            dependencies: [],
            path: "Sources/KasetCLI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        
        .testTarget(
            name: "KasetTests",
            dependencies: ["Kaset"],
            path: "Tests/KasetTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]
        ),
    ]
)
```

### Considerations

| Item | Notes |
|------|-------|
| **Resources** | Asset catalogs compiled via script, not SwiftPM resources |
| **Sparkle linking** | Framework copied to bundle by packaging script |
| **CLI target** | Optional, could include api-explorer |
| **UI Tests** | Not in Package.swift, handled separately |

---

## Resource Handling

### Asset Catalog Compilation

```bash
compile_assets() {
  local assets_path="$1"
  local output_dir="$2"
  
  xcrun actool "$assets_path" \
    --compile "$output_dir" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --accent-color AccentColor \
    --output-partial-info-plist "$output_dir/Assets-Info.plist"
}
```

### Icon Bundle Conversion

```bash
convert_icon() {
  local icon_bundle="$1"
  local output_icns="$2"
  
  # macOS 14+ .icon bundles need iconutil
  if [[ -d "$icon_bundle" ]]; then
    iconutil --convert icns --output "$output_icns" "$icon_bundle"
  fi
}
```

### Info.plist Generation

```bash
generate_info_plist() {
  local template="$1"
  local output="$2"
  
  sed \
    -e "s/\${MARKETING_VERSION}/${MARKETING_VERSION}/" \
    -e "s/\${BUILD_NUMBER}/${BUILD_NUMBER}/" \
    -e "s/\${BUNDLE_ID}/${BUNDLE_ID}/" \
    "$template" > "$output"
}
```

---

## Build Configurations

### Debug vs Release

| Aspect | Debug | Release |
|--------|-------|---------|
| Swift flags | `-DDEBUG`, `-DVERBOSE_LOGGING` | (none) |
| Optimization | `-Onone` | `-O` |
| Sandbox | Disabled | Enabled |
| Entitlements | `Kaset.Debug.entitlements` | `Kaset.entitlements` |
| Code signing | Ad-hoc or dev | Developer ID |
| Sparkle feed | Empty (no updates) | Production URL |

### Environment Variables

```bash
# version.env
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.sertacozercan.Kaset
TEAM_ID=XXXXXXXXXX
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SPARKLE_FEED_URL="https://raw.githubusercontent.com/sozercan/kaset/main/appcast.xml"
SPARKLE_PUBLIC_KEY="qa2zoeXHqn+pluxQSGjn5HyIYA/iFtrEJz7S1BoslpI="
```

---

## Testing Strategy

### Unit Tests

| Framework | Use Case |
|-----------|----------|
| Swift Testing | New tests (`@Test`, `@Suite`, `#expect`) |
| XCTest | Performance tests (`measure {}`), legacy |

```bash
# Run all unit tests
swift test

# Run specific test
swift test --filter KasetTests.HomeViewModelTests

# With verbose output
swift test --verbose
```

### UI Tests

Since SwiftPM doesn't support UI test bundles natively:

#### Option A: Minimal xcodeproj (Recommended)

Keep stripped-down `.xcodeproj` with only:
- KasetUITests target
- Reference to built `Kaset.app`

```bash
# Build app first
./Scripts/package_app.sh debug

# Run UI tests
xcodebuild test \
  -scheme KasetUITests \
  -destination 'platform=macOS' \
  -only-testing:KasetUITests/SidebarUITests
```

#### Option B: Process Launch (Future)

```swift
// In a regular test target
func testLaunchApp() throws {
    let app = NSWorkspace.shared.open(URL(fileURLWithPath: "Kaset.app"))
    // ... XCUIApplication-like testing via Accessibility APIs
}
```

---

## Signing & Notarization

### Code Signing Workflow

```
┌─────────────────┐
│  swift build    │
│  -c release     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ package_app.sh  │
│ (bundle + sign) │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────┐
│ Sign frameworks first          │
│ codesign Sparkle.framework     │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Sign main app with entitlements │
│ codesign --options runtime      │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Create zip                      │
│ ditto -c -k --keepParent        │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Submit to Apple notarization    │
│ xcrun notarytool submit --wait  │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Staple ticket                   │
│ xcrun stapler staple            │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Final zip for distribution      │
└─────────────────────────────────┘
```

### Entitlements

**Release (Sandboxed)**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.cs.jit</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

**Debug (Non-Sandboxed)**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.jit</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

---

## CI/CD Considerations

### GitHub Actions Secrets Required

| Secret | Purpose |
|--------|---------|
| `DEVELOPER_ID_CERT` | Base64-encoded .p12 certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | Certificate password |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_ID_PASSWORD` | App-specific password |
| `TEAM_ID` | Apple Developer Team ID |
| `SPARKLE_PRIVATE_KEY` | For signing appcast (Ed25519) |

### Build Matrix

```yaml
strategy:
  matrix:
    include:
      - name: Intel
        arch: x86_64
      - name: Apple Silicon
        arch: arm64
      - name: Universal
        arch: "arm64 x86_64"
```

### Caching

```yaml
- uses: actions/cache@v4
  with:
    path: |
      .build
      ~/Library/Caches/org.swift.swiftpm
    key: ${{ runner.os }}-spm-${{ hashFiles('Package.resolved') }}
```

---

## Risk Assessment

### High Risk

| Risk | Mitigation |
|------|------------|
| Breaking existing workflow | Keep xcodeproj until fully validated |
| Sparkle framework embedding issues | Test thoroughly on clean Mac |
| Notarization regressions | Test on fresh macOS install |
| UI test breakage | Keep minimal xcodeproj for UI tests |

### Medium Risk

| Risk | Mitigation |
|------|------------|
| Build time regressions | Benchmark before/after |
| Resource loading failures | Verify all resource paths in bundle |
| SwiftPM bugs on macOS 26 | Test with latest Swift toolchain |

### Low Risk

| Risk | Mitigation |
|------|------------|
| Developer onboarding friction | Document everything |
| Script maintenance burden | Keep scripts simple, well-commented |

---

## Rollback Strategy

### If Migration Fails

1. **Phase 1-2 failures**: Simply discard branch, xcodeproj unchanged
2. **Phase 3+ failures**: 
   - Revert directory structure changes
   - Restore original xcodeproj file references
   - Delete Package.swift and Scripts/

### Staged Rollback Points

| Checkpoint | Restore Command |
|------------|-----------------|
| After Phase 1 | `git checkout main -- Kaset.xcodeproj/` |
| After Phase 2 | `git checkout main -- App/ Core/ Views/` |
| After Phase 3+ | `git checkout main` (full revert) |

---

## Success Criteria

### Phase Completion Gates

| Phase | Gate |
|-------|------|
| Phase 0 | Documentation complete |
| Phase 1 | `swift build` compiles successfully |
| Phase 2 | Resources compile and bundle correctly |
| Phase 3 | `package_app.sh` produces runnable app |
| Phase 4 | `compile_and_run.sh` works end-to-end |
| Phase 5 | All tests pass (unit + UI) |
| Phase 6 | Notarized app passes Gatekeeper |
| Phase 7 | CI/CD pipelines green |
| Phase 8 | Documentation updated, PR merged |

### Final Validation Checklist

- [ ] `swift build` completes in < 60 seconds (clean)
- [ ] `swift test` passes all unit tests
- [ ] Packaged app launches correctly
- [ ] URL scheme (`kaset://`) works
- [ ] Sparkle updates work (check for updates)
- [ ] App sandbox enforced in release build
- [ ] Notarization succeeds
- [ ] Gatekeeper passes on fresh Mac
- [ ] CI builds are green
- [ ] No regressions in existing functionality

---

## References

### CodexBar (Reference Implementation)

- **Repository**: github.com/steipete/CodexBar
- **Key files**:
  - `Package.swift` — SwiftPM configuration
  - `Scripts/package_app.sh` — App bundling
  - `Scripts/compile_and_run.sh` — Dev loop
  - `Scripts/sign-and-notarize.sh` — Release signing
  - `AGENTS.md` — Build instructions

### Apple Documentation

- [Creating a Mac App with SwiftPM](https://developer.apple.com/documentation/xcode/creating-a-mac-app-with-swift-package-manager)
- [Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)

### SwiftPM Documentation

- [Package.swift Manifest Reference](https://developer.apple.com/documentation/packagedescription)
- [Swift Package Manager Usage](https://www.swift.org/package-manager/)

---

## Timeline Estimate

| Phase | Estimated Duration |
|-------|-------------------|
| Phase 0: Preparation | 2-4 hours |
| Phase 1: Package.swift | 4-6 hours |
| Phase 2: Resources | 4-6 hours |
| Phase 3: Packaging Script | 8-12 hours |
| Phase 4: Dev Loop | 2-4 hours |
| Phase 5: Testing | 4-6 hours |
| Phase 6: Signing | 4-6 hours |
| Phase 7: CI/CD | 4-6 hours |
| Phase 8: Cleanup | 2-4 hours |

**Total**: 34-54 hours (~4-7 working days)

---

## Notes

- This plan is based on CodexBar's proven SwiftPM-only approach
- UI tests remain the biggest complexity; minimal xcodeproj recommended
- Can be executed incrementally across multiple PRs
- Each phase has clear exit criteria for go/no-go decisions
