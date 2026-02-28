#!/bin/bash
#
# sign-update.sh - Signs a release DMG/ZIP for Sparkle distribution
#
# Usage:
#   ./Tools/sign-update.sh path/to/Kaset.dmg
#
# Prerequisites:
#   1. Sparkle must be added as a Swift Package dependency
#   2. Build the project at least once to download Sparkle artifacts
#   3. Set SPARKLE_PRIVATE_KEY environment variable or pass --key flag
#
# The script outputs the EdDSA signature that should be added to appcast.xml
# as the sparkle:edSignature attribute.
#
# Example output:
#   sparkle:edSignature="abc123..."
#   length="12345678"

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

# Find Sparkle's sign_update binary
find_sparkle_bin() {
    local derived_data_paths=(
        "$HOME/Library/Developer/Xcode/DerivedData"
        "./DerivedData"
        "../DerivedData"
    )
    
    for base in "${derived_data_paths[@]}"; do
        if [[ -d "$base" ]]; then
            local found
            found=$(find "$base" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
            if [[ -n "$found" && -x "$found" ]]; then
                echo "$found"
                return 0
            fi
        fi
    done
    
    # Check if installed via Homebrew
    if command -v sign_update &>/dev/null; then
        echo "sign_update"
        return 0
    fi
    
    return 1
}

# Main
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <path-to-dmg-or-zip> [--key <private-key-file>]"
        echo ""
        echo "Signs a release archive for Sparkle distribution."
        echo ""
        echo "Options:"
        echo "  --key <file>    Path to EdDSA private key file"
        echo ""
        echo "Environment:"
        echo "  SPARKLE_PRIVATE_KEY    EdDSA private key (base64 encoded)"
        exit 1
    fi
    
    local archive_path="$1"
    shift
    
    # Parse optional arguments
    local key_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key)
                key_file="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Validate archive exists
    if [[ ! -f "$archive_path" ]]; then
        print_error "Archive not found: $archive_path"
        exit 1
    fi
    
    # Find sign_update binary
    local sign_update_bin
    if ! sign_update_bin=$(find_sparkle_bin); then
        print_error "Could not find Sparkle's sign_update binary."
        echo ""
        echo "Please ensure:"
        echo "  1. Sparkle is added as a Swift Package dependency"
        echo "  2. Build the project at least once: xcodebuild -scheme Kaset build"
        echo ""
        echo "Alternatively, install Sparkle via Homebrew:"
        echo "  brew install sparkle"
        exit 1
    fi
    
    print_success "Found sign_update: $sign_update_bin"
    
    # Build sign command
    local sign_cmd=("$sign_update_bin")
    
    if [[ -n "$key_file" ]]; then
        sign_cmd+=("--ed-key-file" "$key_file")
    elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
        # Write key to temp file for security
        local temp_key
        temp_key=$(mktemp)
        trap 'rm -f "$temp_key"' EXIT
        echo "$SPARKLE_PRIVATE_KEY" > "$temp_key"
        sign_cmd+=("--ed-key-file" "$temp_key")
    fi
    
    sign_cmd+=("$archive_path")
    
    echo ""
    echo "Signing archive..."
    echo ""
    
    # Run sign_update
    "${sign_cmd[@]}"
    
    echo ""
    print_success "Signing complete!"
    echo ""
    echo "Add the above values to your appcast.xml <enclosure> element."
}

main "$@"
