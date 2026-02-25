#!/bin/bash
#
# generate-appcast.sh - Generates/updates appcast.xml from signed releases
#
# Usage:
#   ./Tools/generate-appcast.sh [releases-directory]
#
# This script uses Sparkle's generate_appcast tool to automatically create
# or update the appcast.xml file based on signed release archives.
#
# Prerequisites:
#   1. Sparkle must be added as a Swift Package dependency
#   2. Build the project at least once to download Sparkle artifacts
#   3. Have signed DMG/ZIP files in the releases directory
#
# The releases directory should contain:
#   - Signed .dmg or .zip files for each version
#   - The private EdDSA key (or set SPARKLE_PRIVATE_KEY env var)

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

# Find Sparkle's generate_appcast binary
find_sparkle_bin() {
    local derived_data_paths=(
        "$HOME/Library/Developer/Xcode/DerivedData"
        "./DerivedData"
        "../DerivedData"
    )
    
    for base in "${derived_data_paths[@]}"; do
        if [[ -d "$base" ]]; then
            local found
            found=$(find "$base" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" -type f 2>/dev/null | head -1)
            if [[ -n "$found" && -x "$found" ]]; then
                echo "$found"
                return 0
            fi
        fi
    done
    
    # Check if installed via Homebrew
    if command -v generate_appcast &>/dev/null; then
        echo "generate_appcast"
        return 0
    fi
    
    return 1
}

# Main
main() {
    local releases_dir="${1:-./releases}"
    
    # Validate releases directory exists
    if [[ ! -d "$releases_dir" ]]; then
        print_warning "Releases directory not found: $releases_dir"
        echo "Creating directory..."
        mkdir -p "$releases_dir"
        echo ""
        echo "Please add your signed release archives to: $releases_dir"
        echo "Then run this script again."
        exit 0
    fi
    
    # Check for release files
    local release_count
    release_count=$(find "$releases_dir" -maxdepth 1 \( -name "*.dmg" -o -name "*.zip" \) 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$release_count" -eq 0 ]]; then
        print_error "No release archives found in: $releases_dir"
        echo ""
        echo "Please add .dmg or .zip files to the releases directory."
        exit 1
    fi
    
    print_success "Found $release_count release archive(s)"
    
    # Find generate_appcast binary
    local generate_appcast_bin
    if ! generate_appcast_bin=$(find_sparkle_bin); then
        print_error "Could not find Sparkle's generate_appcast binary."
        echo ""
        echo "Please ensure:"
        echo "  1. Sparkle is added as a Swift Package dependency"
        echo "  2. Build the project at least once: xcodebuild -scheme Kaset build"
        echo ""
        echo "Alternatively, install Sparkle via Homebrew:"
        echo "  brew install sparkle"
        exit 1
    fi
    
    print_success "Found generate_appcast: $generate_appcast_bin"
    
    echo ""
    echo "Generating appcast.xml..."
    echo ""
    
    # Run generate_appcast
    # Output goes to the releases directory, then we copy to repo root
    "$generate_appcast_bin" "$releases_dir"
    
    # Copy generated appcast to repo root if it was created in releases dir
    if [[ -f "$releases_dir/appcast.xml" ]]; then
        cp "$releases_dir/appcast.xml" ./appcast.xml
        print_success "Copied appcast.xml to repository root"
    fi
    
    echo ""
    print_success "Appcast generation complete!"
    echo ""
    echo "Review appcast.xml and commit the changes."
}

main "$@"
