#!/usr/bin/env bash
# Build script to create Kaset.app bundle
# Based on Kuyruk/CodexBar packaging approach

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Load version info
source "$ROOT/version.env"

# Configuration
CONF=${1:-release}
SIGNING_MODE=${KASET_SIGNING:-dev}
APP_NAME="Kaset"
BUNDLE_ID="com.sertacozercan.Kaset"
BUILD_DIR="$ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Build for host architecture by default; allow overriding via ARCHES (e.g., "arm64 x86_64" for universal).
ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  case "$HOST_ARCH" in
    arm64) ARCH_LIST=(arm64) ;;
    x86_64) ARCH_LIST=(x86_64) ;;
    *) ARCH_LIST=("$HOST_ARCH") ;;
  esac
fi

echo "🔨 Building $APP_NAME ($CONF) for ${ARCH_LIST[*]}..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build for each architecture
for ARCH in "${ARCH_LIST[@]}"; do
  echo "  → Building for $ARCH..."
  swift build -c "$CONF" --arch "$ARCH"
done

# Create app bundle structure
echo "📦 Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Build path helper
build_product_path() {
  local name="$1"
  local arch="$2"
  case "$arch" in
    arm64|x86_64) echo ".build/${arch}-apple-macosx/$CONF/$name" ;;
    *) echo ".build/$CONF/$name" ;;
  esac
}

# Verify binary architectures
verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

# Install binary (handles universal builds)
install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

# Copy executable
install_binary "$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate Info.plist with build metadata
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 Sertac Ozercan. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>

    <!-- URL Scheme Registration -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.sertacozercan.kaset</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>kaset</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>

    <!-- Sparkle Auto-Update Configuration -->
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/sozercan/kaset/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>qa2zoeXHqn+pluxQSGjn5HyIYA/iFtrEJz7S1BoslpI=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key>
    <true/>

    <!-- AppleScript Support -->
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>OSAScriptingDefinition</key>
    <string>Kaset.sdef</string>

    <!-- Build Metadata -->
    <key>KasetBuildTimestamp</key>
    <string>${BUILD_TIMESTAMP}</string>
    <key>KasetGitCommit</key>
    <string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy AppleScript definition
SDEF_PATH="$ROOT/Sources/Kaset/Resources/Kaset.sdef"
if [[ -f "$SDEF_PATH" ]]; then
  echo "📜 Copying AppleScript definition..."
  cp "$SDEF_PATH" "$APP_BUNDLE/Contents/Resources/Kaset.sdef"
fi

# Convert .icon bundle to .icns if present
ICON_SOURCE="$ROOT/Sources/Kaset/Resources/kaset.icon"
if [[ -d "$ICON_SOURCE" ]]; then
  echo "🎨 Converting app icon..."
  iconutil --convert icns --output "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$ICON_SOURCE" 2>/dev/null || {
    echo "WARN: iconutil conversion failed; icon may not display correctly."
  }
fi

# Embed Sparkle.framework
SPARKLE_FRAMEWORK=""
for arch in "${ARCH_LIST[@]}"; do
  CANDIDATE=$(build_product_path "" "$arch")
  CANDIDATE_DIR=$(dirname "$CANDIDATE")
  if [[ -d "$CANDIDATE_DIR/Sparkle.framework" ]]; then
    SPARKLE_FRAMEWORK="$CANDIDATE_DIR/Sparkle.framework"
    break
  fi
done

# Also check the default build path
if [[ -z "$SPARKLE_FRAMEWORK" ]] && [[ -d ".build/$CONF/Sparkle.framework" ]]; then
  SPARKLE_FRAMEWORK=".build/$CONF/Sparkle.framework"
fi

if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  echo "✨ Embedding Sparkle.framework..."
  cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
  chmod -R a+rX "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
  echo "WARN: Sparkle.framework not found in build output. Auto-updates will not work."
fi

# SwiftPM resource bundles are emitted next to the built binary
FIRST_ARCH="${ARCH_LIST[0]}"
BINARY_PATH=$(build_product_path "$APP_NAME" "$FIRST_ARCH")
PREFERRED_BUILD_DIR=$(dirname "$BINARY_PATH")
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    bundle_name=$(basename "$bundle")
    echo "  → Copying resource bundle: $bundle_name"
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
  done
fi

# Strip extended attributes to prevent AppleDouble (._*) files that break code sealing
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name '._*' -delete 2>/dev/null || true

# Sign the app
echo "🔏 Signing app..."
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  CODESIGN_ARGS=(--force --sign -)
elif [[ "$SIGNING_MODE" == "dev" ]]; then
  # Use Apple Development certificate
  CODESIGN_HASH=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
  if [[ -z "$CODESIGN_HASH" ]]; then
    echo "WARN: No Apple Development certificate found. Falling back to ad-hoc signing."
    CODESIGN_ARGS=(--force --sign -)
  else
    CODESIGN_ARGS=(--force --sign "$CODESIGN_HASH")
  fi
else
  CODESIGN_ID="${APP_IDENTITY:-Developer ID Application}"
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$CODESIGN_ID")
fi

resign() { codesign "${CODESIGN_ARGS[@]}" "$1"; }

# Sign Sparkle components (innermost first)
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  echo "  → Signing Sparkle.framework..."
  # Sign nested binaries first
  [[ -f "$SPARKLE/Versions/B/Sparkle" ]] && resign "$SPARKLE/Versions/B/Sparkle"
  [[ -f "$SPARKLE/Versions/B/Autoupdate" ]] && resign "$SPARKLE/Versions/B/Autoupdate"
  [[ -d "$SPARKLE/Versions/B/Updater.app" ]] && {
    [[ -f "$SPARKLE/Versions/B/Updater.app/Contents/MacOS/Updater" ]] && resign "$SPARKLE/Versions/B/Updater.app/Contents/MacOS/Updater"
    resign "$SPARKLE/Versions/B/Updater.app"
  }
  [[ -d "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" ]] && {
    [[ -f "$SPARKLE/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" ]] && resign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    resign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  }
  [[ -d "$SPARKLE/Versions/B/XPCServices/Installer.xpc" ]] && {
    [[ -f "$SPARKLE/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" ]] && resign "$SPARKLE/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    resign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  }
  resign "$SPARKLE/Versions/B" 2>/dev/null || true
  resign "$SPARKLE"
fi

# Sign the app bundle with entitlements
if [[ -f "$ROOT/Kaset.entitlements" ]]; then
  codesign "${CODESIGN_ARGS[@]}" --entitlements "$ROOT/Kaset.entitlements" "$APP_BUNDLE"
else
  codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"
fi

echo ""
echo "✅ Build complete!"
echo "📍 App location: $APP_BUNDLE"
echo "   Version: ${MARKETING_VERSION} (${BUILD_NUMBER})"
echo "   Commit:  ${GIT_COMMIT}"
echo "   Arches:  ${ARCH_LIST[*]}"
echo ""
echo "To run: open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE /Applications/"
