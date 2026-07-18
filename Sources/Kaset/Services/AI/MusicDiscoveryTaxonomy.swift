import Foundation
import NaturalLanguage

enum MusicDiscoveryTaxonomy {
    static let groundingStopWords: Set<String> = [
        "a", "an", "and", "by", "for", "music", "of", "songs", "the", "to",
    ]

    static let genreKeywords: Set<String> = [
        "a cappella", "acoustic", "alternative", "ballads", "blues", "classical", "country",
        "dance", "edm", "electronic", "folk", "funk", "guitar", "hip hop", "hiphop", "house",
        "indie", "instrumental", "j pop", "jazz", "jpop", "k pop", "kpop", "latin", "lo fi",
        "lofi", "metal", "orchestral", "piano", "pop", "r b", "rap", "reggae", "rnb", "rock",
        "soul", "synthwave", "techno", "vocal",
    ]

    static let activityKeywords = [
        "bedtime", "coding", "commute", "cooking", "driving", "exercise", "exercising", "focus", "party",
        "running", "sleep", "sleeping", "study", "studying", "workout", "working out", "yoga",
    ]

    static func containsActivityContext(_ query: String) -> Bool {
        !self.activityEvidencePhrases(in: query).isEmpty
    }

    static func activityEvidencePhrases(in query: String) -> [String] {
        let words = Self.normalizedTokens(query)
        guard !words.isEmpty else { return [] }

        var evidence: [String] = []
        func appendEvidence(_ phrase: String) {
            if !evidence.contains(phrase) {
                evidence.append(phrase)
            }
        }

        for index in words.indices {
            let marker = words[index]
            if marker == "for" || marker == "while" {
                var activityStart = words.index(after: index)
                if marker == "for", activityStart < words.endIndex,
                   ["a", "an", "the"].contains(words[activityStart])
                {
                    activityStart = words.index(after: activityStart)
                }
                if let phrase = Self.activityPhrase(at: activityStart, in: words) {
                    appendEvidence(phrase)
                }
            } else if marker == "to",
                      words[..<index].contains(where: Self.contentNouns.contains),
                      let phrase = Self.activityPhrase(at: words.index(after: index), in: words)
            {
                appendEvidence(phrase)
            }
        }

        for nounIndex in words.indices where Self.contentNouns.contains(words[nounIndex]) {
            for phrase in Self.activityEvidenceVocabulary {
                let phraseWords = Self.normalizedTokens(phrase)
                guard nounIndex >= phraseWords.count else { continue }
                let phraseStart = nounIndex - phraseWords.count
                if phraseStart > words.startIndex, words[phraseStart - 1] == "to" {
                    continue
                }
                if Array(words[phraseStart ..< nounIndex]) == phraseWords {
                    appendEvidence(phrase)
                    break
                }
            }
        }

        return evidence
    }

    static func requiresLexicalGrounding(for query: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(query)
        guard let language = recognizer.dominantLanguage else { return true }
        return language == .english
    }

    static func containsRoutingPopularityKeyword(_ query: String) -> Bool {
        let words = Self.normalizedTokens(query)
        let popularityKeywords = ["best", "chart", "charts", "hits", "popular", "top", "trending"]
        return popularityKeywords.contains { Self.containsPhrase($0, in: words) }
    }

    static func containsEraReference(_ query: String) -> Bool {
        let normalizedQuery = Self.normalizedPhrase(query)
        let eraWords = [
            "aughts", "classic", "eighties", "nineties", "noughties", "oldies",
            "seventies", "sixties", "y2k",
        ]
        if eraWords.contains(where: { Self.containsPhrase($0, in: Self.normalizedTokens(query)) }) {
            return true
        }
        return normalizedQuery.range(
            of: #"\b(?:(?:19|20)?\d0s|(?:19|20)\d{2})\b"#,
            options: .regularExpression
        ) != nil
    }

    static func year(in query: String, representsEra era: String) -> Bool {
        guard let eraToken = normalizedTokens(era).first,
              let decade = Int(eraToken.filter(\.isNumber))
        else {
            return false
        }
        return Self.normalizedTokens(query).compactMap(Int.init).contains { year in
            year >= decade && year < decade + 10
        }
    }

    static func genreAliases(for genre: String) -> [String] {
        let normalizedGenre = Self.normalizedPhrase(genre)
        guard let group = Self.genreSynonymGroups.first(where: { $0.contains(normalizedGenre) }) else {
            return []
        }
        return group.filter { $0 != normalizedGenre }
    }

    static func moodAliases(for mood: String) -> [String] {
        let normalizedMood = Self.normalizedPhrase(mood)
        guard let group = Self.moodSynonymGroups.first(where: { $0.contains(normalizedMood) }) else {
            return []
        }
        return group.filter { $0 != normalizedMood }
    }

    static func genre(forMood mood: String) -> String {
        switch mood.lowercased() {
        case "energetic", "upbeat", "happy": "dance"
        case "chill", "relaxing", "peaceful", "mellow": "chill"
        case "sad", "melancholic": "ballads"
        case "romantic": "love"
        case "aggressive", "intense": "rock"
        case "groovy", "funky": "funk"
        case "dark": "alternative"
        default: mood
        }
    }

    static func normalizedEra(_ era: String) -> String {
        let lowered = era.lowercased()
        for decade in stride(from: 1960, through: 2020, by: 10) where lowered.contains(String(decade)) {
            return decade == 2000 ? "2000s" : "\(decade % 100)s"
        }
        return era
    }

    static func isKnownMood(_ mood: String) -> Bool {
        let normalizedMood = Self.normalizedPhrase(mood)
        return Self.moodSynonymGroups.contains { $0.contains(normalizedMood) }
    }

    static func moodAndActivityAreEquivalent(
        mood: String,
        activity: String,
        activityAliases: [String]
    ) -> Bool {
        let moodValues = [mood] + Self.moodAliases(for: mood)
        let activityValues = [activity] + activityAliases
        let normalizedMoodValues = Set(moodValues.map(Self.normalizedPhrase))
        return activityValues.contains { normalizedMoodValues.contains(Self.normalizedPhrase($0)) }
    }

    private static let moodSynonymGroups = [
        ["chill", "relax", "relaxed", "relaxing", "calm", "peaceful", "ambient", "lo fi", "lofi", "mellow", "cozy", "dreamy"],
        ["energetic", "energy", "upbeat", "happy", "feel good", "pump", "hype", "uplifting", "party", "workout"],
        ["sad", "melancholic", "melancholy", "heartbreak", "emotional", "moody"],
        ["focus", "study", "concentrate", "concentration", "work", "productivity"],
        ["romantic", "romance", "love", "date"],
        ["sleep", "sleeping", "bedtime", "night"],
        ["aggressive", "angry", "intense"],
        ["groovy", "funky"],
    ]

    private static let genreSynonymGroups = [
        ["hip hop", "hiphop", "rap"],
        ["electronic", "edm"],
        ["r b", "r and b", "rnb"],
        ["j pop", "jpop"],
        ["k pop", "kpop"],
        ["lo fi", "lofi"],
    ]

    private static let contentNouns: Set<String> = [
        "mix", "mixes", "music", "playlist", "playlists", "song", "songs", "track", "tracks",
    ]

    private static let activityEvidenceVocabulary = [
        "work out", "working out",
        "bedtime", "code", "coding", "commute", "commuting", "cook", "cooking",
        "drive", "driving", "exercise", "exercising", "focus", "focusing", "party",
        "relax", "relaxing", "run", "running", "sleep", "sleeping", "study", "studying",
        "workout", "workouts", "yoga",
    ]

    private static func activityPhrase(at start: Int, in words: [String]) -> String? {
        guard start < words.endIndex else { return nil }
        for phrase in self.activityEvidenceVocabulary {
            let phraseWords = Self.normalizedTokens(phrase)
            guard start + phraseWords.count <= words.count else { continue }
            if Array(words[start ..< start + phraseWords.count]) == phraseWords {
                return phrase
            }
        }
        return nil
    }

    private static func normalizedPhrase(_ value: String) -> String {
        self.normalizedTokens(value).joined(separator: " ")
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func containsPhrase(_ phrase: String, in words: [String]) -> Bool {
        let phraseWords = Self.normalizedTokens(phrase)
        guard !phraseWords.isEmpty, phraseWords.count <= words.count else { return false }
        return (0 ... (words.count - phraseWords.count)).contains { start in
            Array(words[start ..< start + phraseWords.count]) == phraseWords
        }
    }
}
