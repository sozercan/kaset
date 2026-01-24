#!/bin/bash
# Kaset AppleScript Test Script
# Tests all available AppleScript commands via osascript

set -e

echo "========================================="
echo "Kaset AppleScript Commands Test"
echo "========================================="
echo ""

# Check if Kaset is running
if ! pgrep -x "Kaset" > /dev/null; then
    echo "⚠️  Kaset is not running. Starting it..."
    open -a Kaset
    sleep 3
fi

echo "1. Testing 'get player info'..."
osascript -e 'tell application "Kaset" to get player info' || echo "   ❌ Failed"
echo ""

echo "2. Testing 'play'..."
osascript -e 'tell application "Kaset" to play' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

sleep 1

echo "3. Testing 'pause'..."
osascript -e 'tell application "Kaset" to pause' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "4. Testing 'playpause'..."
osascript -e 'tell application "Kaset" to playpause' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "5. Testing 'next track'..."
osascript -e 'tell application "Kaset" to next track' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "6. Testing 'previous track'..."
osascript -e 'tell application "Kaset" to previous track' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "7. Testing 'set volume 50'..."
osascript -e 'tell application "Kaset" to set volume 50' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "8. Testing 'set volume 100'..."
osascript -e 'tell application "Kaset" to set volume 100' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "9. Testing 'toggle mute'..."
osascript -e 'tell application "Kaset" to toggle mute' && echo "   ✅ OK" || echo "   ❌ Failed"
sleep 0.5
osascript -e 'tell application "Kaset" to toggle mute' # Unmute
echo ""

echo "10. Testing 'toggle shuffle'..."
osascript -e 'tell application "Kaset" to toggle shuffle' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "11. Testing 'cycle repeat'..."
osascript -e 'tell application "Kaset" to cycle repeat' && echo "   ✅ Cycle 1 OK (all)" || echo "   ❌ Failed"
osascript -e 'tell application "Kaset" to cycle repeat' && echo "   ✅ Cycle 2 OK (one)" || echo "   ❌ Failed"
osascript -e 'tell application "Kaset" to cycle repeat' && echo "   ✅ Cycle 3 OK (off)" || echo "   ❌ Failed"
echo ""

echo "12. Testing 'like track'..."
osascript -e 'tell application "Kaset" to like track' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "13. Testing 'dislike track'..."
osascript -e 'tell application "Kaset" to dislike track' && echo "   ✅ OK" || echo "   ❌ Failed"
echo ""

echo "========================================="
echo "Final Player State:"
echo "========================================="
osascript -e 'tell application "Kaset" to get player info' | python3 -m json.tool 2>/dev/null || osascript -e 'tell application "Kaset" to get player info'
echo ""

echo "========================================="
echo "All tests completed!"
echo "========================================="
