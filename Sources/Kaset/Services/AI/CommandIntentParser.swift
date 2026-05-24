import Foundation

@available(macOS 26.0, *)
struct CommandIntentParser {
    func isQueueInspectionQuery(_ query: String) -> Bool {
        if self.deterministicRequest(for: query) != nil {
            return false
        }

        let normalized = self.normalized(query)

        if normalized.contains("queue") {
            return Self.queueInspectionPrefixes.contains { normalized.hasPrefix($0) }
        }

        return Self.upcomingQueueInspectionPrefixes.contains { normalized.hasPrefix($0) } &&
            Self.upcomingQueueInspectionPhrases.contains { normalized.hasSuffix($0) }
    }

    func deterministicRequest(for query: String) -> CommandExecutor.Request? {
        let normalized = self.normalized(query)

        if Self.dislikeCommands.contains(normalized) {
            return .dislike
        }

        if Self.likeCommands.contains(normalized) {
            return .like
        }

        if Self.pauseCommands.contains(normalized) {
            return .pause
        }

        if Self.resumeCommands.contains(normalized) {
            return .resume
        }

        if Self.skipCommands.contains(normalized) {
            return .skip
        }

        if Self.previousCommands.contains(normalized) {
            return .previous
        }

        if Self.clearQueueCommands.contains(normalized) {
            return .clearQueue
        }

        if Self.shuffleQueueCommands.contains(normalized) {
            return .shuffleQueue
        }

        return nil
    }

    func fallbackRequest(for query: String) -> CommandExecutor.Request {
        if let deterministicRequest = self.deterministicRequest(for: query) {
            return deterministicRequest
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmedQuery.lowercased()

        if let searchQuery = self.explicitSearchQuery(from: trimmedQuery) {
            return .openSearch(query: searchQuery)
        }

        if let queueQuery = self.queueQuery(from: trimmedQuery) {
            return .queueSearch(query: self.extractMoodOrGenre(from: queueQuery), description: queueQuery)
        }

        if lowered.contains("shuffle") {
            if lowered.contains("queue") {
                return .shuffleQueue
            }
            return .toggleShuffle
        }

        if lowered.contains("skip") || lowered.contains("next") {
            return .skip
        }

        if lowered.contains("previous") || lowered.contains("back") {
            return .previous
        }

        if lowered.contains("dislike") || lowered.contains("thumbs down") {
            return .dislike
        }

        if lowered == "like" || lowered == "i like this" || lowered == "like this" || lowered == "thumbs up" {
            return .like
        }

        if lowered.contains("clear"), lowered.contains("queue") {
            return .clearQueue
        }

        let playbackQuery = self.playbackQuery(from: trimmedQuery) ?? trimmedQuery
        let resolvedQuery = self.extractMoodOrGenre(from: playbackQuery)
        return .playSearch(query: resolvedQuery, description: playbackQuery)
    }

    private func playbackQuery(from query: String) -> String? {
        let lowered = query.lowercased()
        let prefixes = [
            "play ",
            "listen to ",
            "put on ",
            "start ",
        ]

        for prefix in prefixes where lowered.hasPrefix(prefix) {
            return String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func queueQuery(from query: String) -> String? {
        let lowered = query.lowercased()

        if lowered.hasPrefix("queue ") {
            return String(query.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if lowered.hasPrefix("add ") {
            var cleanQuery = String(query.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = cleanQuery.lowercased().range(of: " to queue") {
                cleanQuery = String(cleanQuery[..<range.lowerBound])
            }
            return cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func explicitSearchQuery(from query: String) -> String? {
        let lowered = query.lowercased()
        let prefixes = [
            "search for ",
            "search ",
            "find ",
            "look up ",
            "show me ",
        ]

        for prefix in prefixes where lowered.hasPrefix(prefix) {
            let searchQuery = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !searchQuery.isEmpty {
                return searchQuery
            }
        }

        return nil
    }

    private func normalized(_ query: String) -> String {
        query
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractMoodOrGenre(from query: String) -> String {
        let lowered = query.lowercased()

        if let likeMatch = self.extractSimilarArtist(from: lowered) {
            return likeMatch
        }

        if let decadeMatch = self.extractDecade(from: lowered) {
            return decadeMatch
        }

        if let activityMatch = self.extractActivity(from: lowered) {
            return activityMatch
        }

        let moodsAndGenres = [
            "chill", "relaxing", "calm", "peaceful", "mellow", "cozy",
            "upbeat", "energetic", "hype", "pump", "intense",
            "happy", "sad", "melancholy", "romantic", "love", "emotional",
            "focus", "concentration", "sleep", "ambient", "dreamy",
            "party", "dance", "groovy", "funky",
            "jazz", "rock", "pop", "hip hop", "hip-hop", "rap",
            "classical", "electronic", "edm", "house", "techno",
            "country", "folk", "indie", "alternative", "metal",
            "r&b", "rnb", "soul", "blues", "reggae",
            "latin", "k-pop", "kpop", "j-pop", "jpop",
            "instrumental", "acoustic", "lo-fi", "lofi", "orchestral",
            "piano", "guitar", "vocal", "a cappella",
        ]

        let moodPatterns = ["something", "some", "anything", "music that", "songs that"]
        let isMoodRequest = moodPatterns.contains { lowered.contains($0) }

        if isMoodRequest {
            for mood in moodsAndGenres where lowered.contains(mood) {
                return "\(mood) music"
            }
        }

        let fillerWords = ["some ", "something ", "anything "]
        var cleaned = query
        for filler in fillerWords where cleaned.lowercased().hasPrefix(filler) {
            cleaned = String(cleaned.dropFirst(filler.count))
            break
        }

        return cleaned
    }

    private func extractSimilarArtist(from query: String) -> String? {
        let patterns = [
            "something like ", "anything like ", "similar to ",
            "artists like ", "songs like ", "music like ",
        ]

        for pattern in patterns {
            if let range = query.range(of: pattern) {
                let artist = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty {
                    return artist
                }
            }
        }
        return nil
    }

    private func extractDecade(from query: String) -> String? {
        let decadePattern = #"(19)?(20)?\d0s"#
        if let regex = try? NSRegularExpression(pattern: decadePattern),
           let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range, in: query)
        {
            let decade = String(query[range])
            if query.contains("something") || query.contains("from the") {
                return "\(decade) music"
            }
        }
        return nil
    }

    private func extractActivity(from query: String) -> String? {
        let activityMappings = [
            "for studying": "study music",
            "for working out": "workout music",
            "for running": "running music",
            "for sleeping": "sleep music",
            "for meditation": "meditation music",
            "for cooking": "cooking music",
            "for driving": "driving music",
            "for reading": "reading music",
            "for work": "focus music",
            "for coding": "coding music",
            "to study": "study music",
            "to sleep": "sleep music",
            "to relax": "relaxing music",
            "to work out": "workout music",
        ]

        for (pattern, replacement) in activityMappings where query.contains(pattern) {
            return replacement
        }
        return nil
    }

    private static let pauseCommands: Set<String> = [
        "pause",
        "pause music",
        "pause the music",
        "stop",
        "stop music",
        "stop the music",
    ]

    private static let resumeCommands: Set<String> = [
        "play",
        "resume",
        "resume music",
        "resume playback",
        "continue",
        "continue playback",
    ]

    private static let skipCommands: Set<String> = [
        "skip",
        "skip song",
        "skip this",
        "skip this song",
        "skip track",
        "next",
        "next song",
        "next track",
    ]

    private static let previousCommands: Set<String> = [
        "previous",
        "previous song",
        "previous track",
        "back",
        "go back",
    ]

    private static let likeCommands: Set<String> = [
        "like",
        "like this",
        "like this song",
        "i like this",
        "thumbs up",
    ]

    private static let dislikeCommands: Set<String> = [
        "dislike",
        "dislike this",
        "dislike this song",
        "thumbs down",
    ]

    private static let clearQueueCommands: Set<String> = [
        "clear queue",
        "clear my queue",
        "empty queue",
        "empty my queue",
    ]

    private static let shuffleQueueCommands: Set<String> = [
        "shuffle queue",
        "shuffle my queue",
        "shuffle the queue",
    ]

    private static let queueInspectionPrefixes: Set<String> = [
        "describe",
        "how many",
        "list",
        "show",
        "tell me",
        "what",
        "what is",
        "what s",
        "whats",
    ]

    private static let upcomingQueueInspectionPrefixes: Set<String> = [
        "show me what",
        "tell me what",
        "what",
        "what is",
        "what s",
        "whats",
    ]

    private static let upcomingQueueInspectionPhrases: Set<String> = [
        "coming up",
        "playing next",
        "up next",
    ]
}
