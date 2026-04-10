import Foundation

// MARK: - FoundationModelsPromptVersion

@available(macOS 26.0, *)
enum FoundationModelsPromptVersion: Equatable {
    case legacy26_0To26_3
    case optimized26_4AndLater

    static var current: Self {
        if #available(macOS 26.4, *) {
            .optimized26_4AndLater
        } else {
            .legacy26_0To26_3
        }
    }

    var logDescription: String {
        switch self {
        case .legacy26_0To26_3:
            "26.0-26.3"
        case .optimized26_4AndLater:
            "26.4+"
        }
    }
}

// MARK: - FoundationModelsPromptLibrary

@available(macOS 26.0, *)
enum FoundationModelsPromptLibrary {
    static func middleTruncate(
        _ text: String,
        targetLength: Int,
        marker: String = "\n...[truncated]...\n"
    ) -> String {
        guard targetLength > 0, text.count > targetLength else { return text }
        guard targetLength > marker.count else {
            return String(text.prefix(targetLength))
        }

        let remainingLength = targetLength - marker.count
        let leadingLength = (remainingLength + 1) / 2
        let trailingLength = remainingLength / 2

        return String(text.prefix(leadingLength)) + marker + String(text.suffix(trailingLength))
    }

    static func commandBarInstructions(
        version: FoundationModelsPromptVersion = .current
    ) -> String {
        switch version {
        case .legacy26_0To26_3:
            """
            You are a music assistant for the Kaset app. Parse the user's natural language command
            and determine what action they want to perform. Return a MusicIntent with:
            1. The action (play, queue, shuffle, like, skip, pause, etc.)
            2. Parsed query components (artist, genre, mood, era, version, activity)
            3. The full original query (IMPORTANT: preserve keywords like "hits", "greatest", "best of")

            PARSE NATURAL LANGUAGE INTO STRUCTURED COMPONENTS:

            Example: "rolling stones 90s hits"
            -> action: play, query: "rolling stones 90s hits", artist: "Rolling Stones", era: "1990s"

            Example: "upbeat rolling stones songs from the 90s"
            -> action: play, query: "upbeat rolling stones songs", artist: "Rolling Stones", mood: "upbeat", era: "1990s"

            Example: "chill jazz for studying"
            -> action: play, query: "chill jazz for studying", genre: "jazz", mood: "chill", activity: "study"

            Example: "acoustic covers of pop hits"
            -> action: play, query: "acoustic covers of pop hits", genre: "pop", version: "acoustic cover"

            Example: "80s synthwave"
            -> action: play, query: "80s synthwave", genre: "synthwave", era: "1980s"

            Example: "add some energetic workout music to queue"
            -> action: queue, query: "energetic workout music", mood: "energetic", activity: "workout"

            Example: "best of queen"
            -> action: play, query: "best of queen", artist: "Queen"

            COMPONENT EXTRACTION RULES:
            - query: ALWAYS include the full natural language request (minus action words)
            - artist: Extract artist name if mentioned ("Beatles", "Taylor Swift", "Rolling Stones")
            - genre: rock, pop, jazz, classical, hip-hop, r&b, electronic, country, folk, metal, indie, latin, k-pop
            - mood: upbeat, chill, sad, happy, energetic, relaxing, melancholic, romantic, aggressive, peaceful, groovy
            - era: Use decade format (1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s) or "classic"
            - version: acoustic, live, remix, instrumental, cover, unplugged, remastered
            - activity: workout, study, sleep, party, driving, cooking, focus, running, yoga

            For simple commands: skip/next -> skip, pause/stop -> pause, play/resume -> resume,
            shuffle my queue -> shuffle (shuffleScope: queue), like this -> like, clear queue -> queue (query: "__clear__")
            """

        case .optimized26_4AndLater:
            """
            You are Kaset's music command parser. Return the best MusicIntent for the user's request.

            Field rules:
            - action: play, queue, shuffle, like, dislike, skip, previous, pause, resume, search
            - query: keep the important search words, including qualifiers like "hits", "greatest", and "best of"
            - artist: artist or band name only
            - genre: rock, pop, jazz, classical, hip-hop, r&b, electronic, country, folk, metal, indie, latin, k-pop
            - mood: upbeat, chill, sad, happy, energetic, relaxing, melancholic, romantic, aggressive, peaceful, groovy
            - era: use 1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s, or classic
            - version: acoustic, live, remix, instrumental, cover, unplugged, remastered
            - activity: workout, study, sleep, party, driving, cooking, focus, running, yoga

            Action rules:
            - skip or next -> skip
            - pause or stop -> pause
            - resume only when the user clearly wants to continue current playback
            - clear queue -> action queue with query "__clear__"
            - shuffle my queue -> action shuffle with shuffleScope "queue"

            Examples:
            - "best of queen" -> play, query "best of queen", artist "Queen"
            - "add some energetic workout music to queue" -> queue, query "energetic workout music", mood "energetic", activity "workout"

            Prefer play for requests to start music and search for explicit browse or lookup requests. Keep the query concise without dropping meaning.
            """
        }
    }

    static func lyricsExplanationInstructions(
        version: FoundationModelsPromptVersion = .current
    ) -> String {
        switch version {
        case .legacy26_0To26_3:
            """
            You are a music critic and lyricist. Analyze song lyrics and provide insights about
            their meaning, themes, and emotional content. Be insightful but accessible.
            Don't be overly academic or pretentious.
            """

        case .optimized26_4AndLater:
            """
            You explain song lyrics for Kaset. Be insightful, concrete, and accessible.
            Use the lyrics as your source of truth, avoid invented background facts,
            and keep the explanation concise.
            """
        }
    }

    static func lyricsExplanationPrompt(
        trackTitle: String,
        artistsDisplay: String,
        lyrics: String,
        version: FoundationModelsPromptVersion = .current
    ) -> String {
        switch version {
        case .legacy26_0To26_3:
            """
            Analyze these lyrics for "\(trackTitle)" by \(artistsDisplay):

            \(lyrics)

            Identify the key themes, overall mood, and explain what the song is about.
            """

        case .optimized26_4AndLater:
            """
            Song: "\(trackTitle)" by \(artistsDisplay)

            Lyrics:
            \(lyrics)

            Task:
            - Identify 2-5 main themes
            - Name the overall mood
            - Explain what the song is saying in 2-4 sentences
            """
        }
    }

    static func playlistRefinementInstructions(
        version: FoundationModelsPromptVersion = .current
    ) -> String {
        switch version {
        case .legacy26_0To26_3:
            """
            You are a music playlist curator. Analyze songs and suggest changes based on the request.

            IMPORTANT RULES:
            - A "duplicate" means the EXACT same video ID appears twice. Different versions/covers
              of a song by different artists are NOT duplicates.
            - "Last Christmas" by Wham! and "Last Christmas" by Jimmy Eat World are DIFFERENT songs.
            - Only suggest removing tracks that truly don't fit the user's criteria.
            - When in doubt, keep the song.
            """

        case .optimized26_4AndLater:
            """
            You curate playlists for Kaset. Suggest the minimum changes needed to satisfy the request.

            Rules:
            - A duplicate means the exact same video ID appears twice.
            - Covers, live versions, remasters, and songs by different artists are not duplicates unless the video ID matches.
            - Only remove tracks that clearly miss the requested vibe or criteria.
            - Prefer keeping songs when uncertain.
            - Reorder only when it meaningfully improves the requested flow.
            - Always include a brief reasoning string, even when no changes are needed.
            """
        }
    }

    static func playlistTrackList(from tracks: [Song], limit: Int) -> String {
        self.playlistTrackLines(from: tracks, limit: limit).joined(separator: "\n")
    }

    static func playlistTrackLines(from tracks: [Song], limit: Int) -> [String] {
        tracks.prefix(limit).enumerated().map { index, track in
            let safeTitle = track.title.prefix(50)
            let safeArtist = track.artistsDisplay.prefix(30)
            return "\(index + 1). \(safeTitle) - \(safeArtist) [id:\(track.videoId)]"
        }
    }

    static func playlistRefinementPrompt(
        trackList: String,
        totalTracks: Int,
        shownTracks: Int,
        request: String,
        version: FoundationModelsPromptVersion = .current
    ) -> String {
        switch version {
        case .legacy26_0To26_3:
            return """
            Playlist (\(totalTracks) songs, showing \(shownTracks)):

            \(trackList)

            Request: \(request)
            """

        case .optimized26_4AndLater:
            let tracksSection = if shownTracks == 0 {
                """
                No track details fit in the on-device context window.
                Return no removals or reordering, and explain that the request needs to be shorter.
                """
            } else {
                trackList
            }

            return """
            Playlist review:
            - Total songs: \(totalTracks)
            - Songs shown: \(shownTracks)

            Tracks:
            \(tracksSection)

            Request: \(request)

            Return only the removals, optional reordering, and a brief reasoning string needed for the request.
            """
        }
    }
}
