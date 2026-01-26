-- Kaset AppleScript Test Script
-- Tests all available AppleScript commands

-- Helper function to display results
on displayResult(commandName, result)
	if result is missing value then
		log commandName & ": OK (no return value)"
	else
		log commandName & ": " & result
	end if
end displayResult

-- Main test routine
tell application "Kaset"

	log "========================================="
	log "Kaset AppleScript Commands Test"
	log "========================================="
	log ""

	-- Test 1: Get Player Info (returns JSON)
	log "1. Testing 'get player info'..."
	try
		set playerInfo to get player info
		log "   Result: " & playerInfo
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 2: Play
	log "2. Testing 'play'..."
	try
		play
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Wait a moment
	delay 1

	-- Test 3: Pause
	log "3. Testing 'pause'..."
	try
		pause
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 4: Play/Pause Toggle
	log "4. Testing 'playpause'..."
	try
		playpause
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 5: Next Track
	log "5. Testing 'next track'..."
	try
		next track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 6: Previous Track
	log "6. Testing 'previous track'..."
	try
		previous track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 7: Set Volume (50%)
	log "7. Testing 'set volume 50'..."
	try
		set volume 50
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 8: Set Volume (100%)
	log "8. Testing 'set volume 100'..."
	try
		set volume 100
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 9: Toggle Mute
	log "9. Testing 'toggle mute'..."
	try
		toggle mute
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Unmute
	delay 0.5
	try
		toggle mute
	end try

	-- Test 10: Toggle Shuffle
	log "10. Testing 'toggle shuffle'..."
	try
		toggle shuffle
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 11: Cycle Repeat
	log "11. Testing 'cycle repeat' (3 times to cycle through all modes)..."
	try
		cycle repeat
		log "   Cycle 1: OK (should be 'all')"
		cycle repeat
		log "   Cycle 2: OK (should be 'one')"
		cycle repeat
		log "   Cycle 3: OK (should be 'off')"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 12: Like Track
	log "12. Testing 'like track'..."
	try
		like track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Test 13: Dislike Track
	log "13. Testing 'dislike track'..."
	try
		dislike track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	-- Final state check
	log "========================================="
	log "Final Player State:"
	log "========================================="
	try
		set finalInfo to get player info
		log finalInfo
	on error errMsg
		log "Error getting final state: " & errMsg
	end try

	log ""
	log "========================================="
	log "All tests completed!"
	log "========================================="

end tell
