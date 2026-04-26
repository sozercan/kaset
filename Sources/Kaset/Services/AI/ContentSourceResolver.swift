import Foundation

@available(macOS 26.0, *)
enum ContentSourceResolver {
    static func buildSearchQuery(from intent: MusicIntent) -> String {
        if !intent.query.isEmpty, intent.artist.isEmpty, intent.genre.isEmpty, intent.mood.isEmpty, intent.era.isEmpty {
            return intent.query
        }

        var parts: [String] = []
        var hasHits = false
        let wantsHits = Self.queryWantsHits(intent.query)

        if !intent.artist.isEmpty {
            (parts, hasHits) = Self.buildArtistQuery(from: intent, wantsHits: wantsHits)
        } else if !intent.era.isEmpty {
            (parts, hasHits) = Self.buildEraQuery(from: intent)
        } else {
            parts = Self.buildGenericQuery(from: intent)
        }

        parts = Self.appendAdditionalComponents(parts, from: intent)

        let hasMusic = parts.contains { $0.lowercased() == "music" }
        if !parts.isEmpty, !hasHits, !hasMusic {
            parts.append("songs")
        }

        return parts.joined(separator: " ")
    }

    static func queryDescription(for intent: MusicIntent) -> String {
        var parts: [String] = []
        let queryLower = intent.query.lowercased()
        let wantsHits = queryLower.contains("hit") || queryLower.contains("best") ||
            queryLower.contains("greatest") || queryLower.contains("top")

        if !intent.mood.isEmpty { parts.append(intent.mood) }
        if !intent.genre.isEmpty { parts.append(intent.genre) }
        if wantsHits { parts.append("hits") }
        if !intent.artist.isEmpty { parts.append("by \(intent.artist)") }
        if !intent.era.isEmpty { parts.append("from the \(intent.era)") }
        if !intent.version.isEmpty { parts.append("(\(intent.version))") }
        if !intent.activity.isEmpty { parts.append("for \(intent.activity)") }

        if parts.isEmpty {
            return intent.query
        }

        return parts.joined(separator: " ")
    }

    static func suggestedContentSource(for intent: MusicIntent) -> ContentSource {
        if !intent.artist.isEmpty {
            return .search
        }

        if !intent.version.isEmpty {
            return .search
        }

        let popularityKeywords = ["top", "popular", "trending", "best", "hits", "charts"]
        let queryLower = intent.query.lowercased()
        if popularityKeywords.contains(where: { queryLower.contains($0) }) {
            return .charts
        }

        let moodMatches = [
            "chill", "relaxing", "calm", "peaceful", "mellow",
            "energetic", "workout", "pump", "hype", "party",
            "focus", "study", "concentration",
            "sad", "melancholic", "heartbreak",
            "happy", "feel good", "upbeat", "uplifting",
            "sleep", "bedtime", "ambient",
            "romantic", "love",
        ]

        let moodLower = intent.mood.lowercased()
        let matchesMood = !intent.mood.isEmpty && moodMatches.contains { moodLower.contains($0) }
        let matchesQuery = moodMatches.contains { queryLower.contains($0) }

        if matchesMood || matchesQuery {
            return .moodsAndGenres
        }

        if !intent.activity.isEmpty {
            return .moodsAndGenres
        }

        if !intent.genre.isEmpty, intent.artist.isEmpty, intent.era.isEmpty {
            return .moodsAndGenres
        }

        return .search
    }

    private static func queryWantsHits(_ query: String) -> Bool {
        let queryLower = query.lowercased()
        return queryLower.contains("hit") || queryLower.contains("best") ||
            queryLower.contains("greatest") || queryLower.contains("top")
    }

    private static func buildArtistQuery(from intent: MusicIntent, wantsHits: Bool) -> ([String], Bool) {
        var parts: [String] = [intent.artist]
        var hasHits = false

        if !intent.era.isEmpty {
            parts.append(Self.normalizeEra(intent.era))
        }

        if wantsHits {
            parts.append("greatest hits")
            hasHits = true
        }

        if !intent.genre.isEmpty { parts.append(intent.genre) }
        if !intent.mood.isEmpty { parts.append(intent.mood) }

        return (parts, hasHits)
    }

    private static func buildEraQuery(from intent: MusicIntent) -> ([String], Bool) {
        var parts: [String] = [Self.normalizeEra(intent.era)]

        if !intent.mood.isEmpty {
            parts.append(Self.moodToGenre(intent.mood))
        } else if !intent.genre.isEmpty {
            parts.append(intent.genre)
        }

        parts.append("hits")
        return (parts, true)
    }

    private static func buildGenericQuery(from intent: MusicIntent) -> [String] {
        var parts: [String] = []
        if !intent.genre.isEmpty { parts.append(intent.genre) }
        if !intent.mood.isEmpty { parts.append(intent.mood) }

        if intent.genre.isEmpty, !intent.mood.isEmpty, intent.artist.isEmpty, intent.activity.isEmpty {
            parts.append("music")
        }

        return parts
    }

    private static func appendAdditionalComponents(_ parts: [String], from intent: MusicIntent) -> [String] {
        var result = parts

        if !intent.query.isEmpty {
            let cleanQuery = Self.cleanQueryForAppending(intent.query)
            if !cleanQuery.isEmpty, cleanQuery.lowercased() != intent.artist.lowercased() {
                result.append(cleanQuery)
            }
        }

        if !intent.version.isEmpty {
            result.append(intent.version)
        }

        if !intent.activity.isEmpty, result.isEmpty {
            result.append("\(intent.activity) music")
        }

        return result
    }

    private static func cleanQueryForAppending(_ query: String) -> String {
        let words = query.lowercased().split(separator: " ")
        let skipWords: Set = [
            "play", "some", "the", "a", "an", "me", "from", "of",
            "songs", "music", "tracks", "hits", "hit", "best", "greatest", "top",
        ]
        let filtered = words.filter { !skipWords.contains(String($0)) }
        return filtered.joined(separator: " ")
    }

    private static func normalizeEra(_ era: String) -> String {
        let lowered = era.lowercased()

        if lowered.contains("1960") { return "60s" }
        if lowered.contains("1970") { return "70s" }
        if lowered.contains("1980") { return "80s" }
        if lowered.contains("1990") { return "90s" }
        if lowered.contains("2000") { return "2000s" }
        if lowered.contains("2010") { return "2010s" }
        if lowered.contains("2020") { return "2020s" }

        return era
    }

    private static func moodToGenre(_ mood: String) -> String {
        let lowered = mood.lowercased()

        return switch lowered {
        case "energetic", "upbeat", "happy":
            "dance"
        case "chill", "relaxing", "peaceful", "mellow":
            "chill"
        case "sad", "melancholic":
            "ballads"
        case "romantic":
            "love"
        case "aggressive", "intense":
            "rock"
        case "groovy", "funky":
            "funk"
        case "dark":
            "alternative"
        default:
            mood
        }
    }
}
