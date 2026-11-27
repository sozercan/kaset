
on displayResult(commandName, result)
	if result is missing value then
		log commandName & ": OK (no return value)"
	else
		log commandName & ": " & result
	end if
end displayResult

tell application "Kaset"

	log "========================================="
	log "Kaset AppleScript Commands Test"
	log "========================================="
	log ""

	log "1. Testing 'get player info'..."
	try
		set playerInfo to get player info
		log "   Result: " & playerInfo
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "2. Testing 'play'..."
	try
		play
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	delay 1

	log "3. Testing 'pause'..."
	try
		pause
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "4. Testing 'playpause'..."
	try
		playpause
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "5. Testing 'next track'..."
	try
		next track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "6. Testing 'previous track'..."
	try
		previous track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "7. Testing 'set volume 50'..."
	try
		set volume 50
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "8. Testing 'set volume 100'..."
	try
		set volume 100
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "9. Testing 'toggle mute'..."
	try
		toggle mute
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	delay 0.5
	try
		toggle mute
	end try

	log "10. Testing 'toggle shuffle'..."
	try
		toggle shuffle
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

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

	log "12. Testing 'like track'..."
	try
		like track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

	log "13. Testing 'dislike track'..."
	try
		dislike track
		log "   OK"
	on error errMsg
		log "   Error: " & errMsg
	end try
	log ""

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
