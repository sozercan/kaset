#!/usr/bin/env bash
# Verifies the packaged Kaset.app has the release-critical settings that are
# easy to regress when building outside Xcode.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_PATH="$ROOT/.build/app/Kaset.app"
REQUIRE_DEVELOPER_ID=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-developer-id)
      REQUIRE_DEVELOPER_ID=true
      shift
      ;;
    --help|-h)
      cat <<USAGE
Usage: Scripts/verify-release-app.sh [--require-developer-id] [path/to/Kaset.app]

Checks:
  - Info.plist contains Sparkle's sandboxed installer launcher key
  - sandbox entitlements include Sparkle's installer/status mach lookups
  - Sparkle Installer.xpc is embedded
  - codesign verification succeeds
  - optional Developer ID Application signing identity is used
USAGE
      exit 0
      ;;
    *)
      APP_PATH="$1"
      shift
      ;;
  esac
done

INFO_PLIST="$APP_PATH/Contents/Info.plist"
ENTITLEMENTS_PLIST=$(mktemp "${TMPDIR:-/tmp}/kaset-entitlements.XXXXXX.plist")
CODESIGN_DETAILS=$(mktemp "${TMPDIR:-/tmp}/kaset-codesign.XXXXXX.txt")
trap 'rm -f "$ENTITLEMENTS_PLIST" "$CODESIGN_DETAILS"' EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist not found: $INFO_PLIST"

plutil -lint "$INFO_PLIST" >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_PLIST" 2>/dev/null || fail "Could not read app entitlements"
plutil -lint "$ENTITLEMENTS_PLIST" >/dev/null
codesign -dv --verbose=4 "$APP_PATH" >"$CODESIGN_DETAILS" 2>&1 || fail "Could not read code signature details"

python3 - "$APP_PATH" "$INFO_PLIST" "$ENTITLEMENTS_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

app_path = Path(sys.argv[1])
info_path = Path(sys.argv[2])
entitlements_path = Path(sys.argv[3])

with info_path.open("rb") as handle:
    info = plistlib.load(handle)
with entitlements_path.open("rb") as handle:
    entitlements = plistlib.load(handle)

errors: list[str] = []
bundle_id = info.get("CFBundleIdentifier")
expected_bundle_id = "com.sertacozercan.Kaset"
if bundle_id != expected_bundle_id:
    errors.append(f"CFBundleIdentifier must be {expected_bundle_id}, found {bundle_id!r}")

if info.get("SUEnableInstallerLauncherService") is not True:
    errors.append("SUEnableInstallerLauncherService must be true for sandboxed Sparkle updates")

installer_xpc = app_path / "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
if not installer_xpc.exists():
    errors.append(f"Sparkle Installer.xpc is missing at {installer_xpc}")

if entitlements.get("com.apple.security.app-sandbox") is True:
    expected_mach_services = {
        f"{expected_bundle_id}-spks",
        f"{expected_bundle_id}-spki",
    }
    actual_mach_services = set(
        entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name") or []
    )
    missing = sorted(expected_mach_services - actual_mach_services)
    if missing:
        errors.append(
            "Sandboxed Sparkle updates require mach lookup exceptions: "
            + ", ".join(missing)
        )
else:
    errors.append("Kaset release app must be sandboxed")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PY

if [[ "$REQUIRE_DEVELOPER_ID" == true ]]; then
  if ! grep -q '^Authority=Developer ID Application:' "$CODESIGN_DETAILS"; then
    cat "$CODESIGN_DETAILS" >&2
    fail "Release builds must be signed with a Developer ID Application certificate"
  fi
  if grep -q '^Authority=Apple Development:' "$CODESIGN_DETAILS"; then
    cat "$CODESIGN_DETAILS" >&2
    fail "Release builds must not be signed with an Apple Development certificate"
  fi
fi

echo "✅ Release app verification passed: $APP_PATH"
