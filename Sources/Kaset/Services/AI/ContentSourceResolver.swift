import Foundation

// MARK: - ContentSourceResolver

@available(macOS 26.0, *)
enum ContentSourceResolver {
    static func buildSearchQuery(
        from intent: MusicIntent,
        groundingQuery: String? = nil
    ) -> String {
        let groundedIntent = Self.groundedIntent(intent, groundingQuery: groundingQuery)
        let popularityQuery = MusicDiscoveryTaxonomy.queryExcludingExplicitTitle(
            groundingQuery ?? groundedIntent.query,
            title: intent.query
        )
        let wantsHits = Self.queryWantsHits(popularityQuery)

        if !groundedIntent.query.isEmpty,
           groundedIntent.artist.isEmpty,
           groundedIntent.genre.isEmpty,
           groundedIntent.mood.isEmpty,
           groundedIntent.era.isEmpty,
           groundedIntent.version.isEmpty,
           groundedIntent.activity.isEmpty
        {
            if wantsHits, !Self.queryWantsHits(groundedIntent.query) {
                return "\(groundedIntent.query) hits"
            }
            return groundedIntent.query
        }

        var parts: [String] = []
        var hasHits = false
        if !groundedIntent.artist.isEmpty {
            (parts, hasHits) = Self.buildArtistQuery(from: groundedIntent, wantsHits: wantsHits)
        } else if !groundedIntent.era.isEmpty {
            (parts, hasHits) = Self.buildEraQuery(from: groundedIntent)
        } else {
            parts = Self.buildGenericQuery(from: groundedIntent)
        }

        parts = Self.appendAdditionalComponents(
            parts,
            from: groundedIntent,
            groundingQuery: groundingQuery ?? intent.query
        )

        if wantsHits, !hasHits {
            Self.appendNovelWords("hits", to: &parts)
            hasHits = true
        }

        let hasMusic = parts.contains { Self.normalizedTokens($0).contains("music") }
        if !parts.isEmpty, !hasHits, !hasMusic {
            parts.append("songs")
        }

        return parts.joined(separator: " ")
    }

    static func suggestedContentSource(
        for intent: MusicIntent,
        groundingQuery: String? = nil
    ) -> ContentSource {
        let intent = Self.groundedIntent(intent, groundingQuery: groundingQuery)
        let routingQuery = groundingQuery ?? intent.query
        let discoveryRoutingQuery = MusicDiscoveryTaxonomy.queryExcludingExplicitTitle(routingQuery, title: intent.query)

        if !intent.artist.isEmpty {
            return .search
        }

        if !intent.version.isEmpty {
            return .search
        }

        if !MusicDiscoveryTaxonomy.activityEvidencePhrases(in: routingQuery).isEmpty,
           Self.hasDistinctSearchSubject(in: intent)
        {
            return .search
        }

        let wantsPopularity = MusicDiscoveryTaxonomy.containsRoutingPopularityKeyword(discoveryRoutingQuery)

        let moodMatches = [
            "chill", "relaxing", "calm", "peaceful", "mellow",
            "energetic", "pump", "hype",
            "sad", "melancholic", "heartbreak",
            "happy", "feel good", "upbeat", "uplifting",
            "ambient",
            "romantic", "love",
        ]

        let moodLower = intent.mood.lowercased()
        let matchesMood = !intent.mood.isEmpty && moodMatches.contains { moodLower.contains($0) }
        let normalizedQuery = Self.normalizedTokens(discoveryRoutingQuery).joined(separator: " ")
        let hasActivityContext = MusicDiscoveryTaxonomy.containsActivityContext(normalizedQuery) ||
            MusicDiscoveryTaxonomy.standaloneActivityPhrase(in: routingQuery) != nil
        let matchesQuery = moodMatches.contains { Self.containsNormalizedPhrase(normalizedQuery, $0) } ||
            hasActivityContext
        let queryMoodKeywords = moodMatches.filter { Self.containsNormalizedPhrase(normalizedQuery, $0) }
        let queryActivityKeywords = MusicDiscoveryTaxonomy.activityKeywords.filter { Self.containsNormalizedPhrase(normalizedQuery, $0) }
        var discoveryDimensions: Set<String> = []
        if !intent.genre.isEmpty || MusicDiscoveryTaxonomy.genreKeywords.contains(where: {
            Self.containsNormalizedPhrase(normalizedQuery, $0)
        }) {
            discoveryDimensions.insert("genre")
        }
        if !intent.mood.isEmpty || queryMoodKeywords.contains(where: { !Self.value($0, isRepresentedBy: intent.activity) }) {
            discoveryDimensions.insert("mood")
        }
        if !intent.activity.isEmpty ||
            (hasActivityContext &&
                queryActivityKeywords.contains(where: { activityKeyword in
                    if Self.value(activityKeyword, isRepresentedBy: intent.mood) {
                        return false
                    }
                    let moodIsExplicit = Self.containsNormalizedPhrase(normalizedQuery, intent.mood)
                    return moodIsExplicit || !MusicDiscoveryTaxonomy.moodAndActivityAreEquivalent(
                        mood: intent.mood,
                        activity: activityKeyword,
                        activityAliases: Self.activityAliases(for: activityKeyword)
                    )
                }))
        {
            discoveryDimensions.insert("activity")
        }
        if !intent.era.isEmpty || MusicDiscoveryTaxonomy.containsEraReference(normalizedQuery) {
            discoveryDimensions.insert("era")
        }

        if wantsPopularity {
            return discoveryDimensions.isEmpty ? .charts : .search
        }

        if discoveryDimensions.count > 1 {
            return .search
        }

        if !intent.mood.isEmpty || matchesMood || matchesQuery {
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
        MusicDiscoveryTaxonomy.containsRoutingPopularityKeyword(query)
    }

    private static func buildArtistQuery(from intent: MusicIntent, wantsHits: Bool) -> ([String], Bool) {
        var parts: [String] = [intent.artist]
        var hasHits = false

        if !intent.era.isEmpty {
            Self.appendNovelWords(MusicDiscoveryTaxonomy.normalizedEra(intent.era), to: &parts)
        }

        if wantsHits {
            Self.appendNovelWords("greatest hits", to: &parts)
            hasHits = true
        }

        if !intent.genre.isEmpty {
            Self.appendNovelWords(intent.genre, to: &parts)
        }
        if !intent.mood.isEmpty {
            Self.appendNovelWords(intent.mood, to: &parts)
        }

        return (parts, hasHits)
    }

    private static func buildEraQuery(from intent: MusicIntent) -> ([String], Bool) {
        var parts: [String] = [MusicDiscoveryTaxonomy.normalizedEra(intent.era)]

        if !intent.mood.isEmpty {
            Self.appendNovelWords(MusicDiscoveryTaxonomy.genre(forMood: intent.mood), to: &parts)
        }
        if !intent.genre.isEmpty {
            Self.appendNovelWords(intent.genre, to: &parts)
        }

        Self.appendNovelWords("hits", to: &parts)
        return (parts, true)
    }

    private static func buildGenericQuery(from intent: MusicIntent) -> [String] {
        var parts: [String] = []
        if !intent.genre.isEmpty {
            Self.appendNovelWords(intent.genre, to: &parts)
        }
        if !intent.mood.isEmpty {
            Self.appendNovelWords(intent.mood, to: &parts)
        }

        if intent.genre.isEmpty, !intent.mood.isEmpty, intent.artist.isEmpty, intent.activity.isEmpty {
            parts.append("music")
        }

        return parts
    }

    private static func appendAdditionalComponents(
        _ parts: [String],
        from intent: MusicIntent,
        groundingQuery: String
    ) -> [String] {
        var result = parts

        if !intent.query.isEmpty {
            let cleanedQuery = Self.cleanQueryForAppending(
                intent.query,
                artist: intent.artist,
                mood: intent.mood,
                activity: intent.activity,
                era: intent.era
            )
            if cleanedQuery.query.lowercased() == intent.artist.lowercased() {
                if cleanedQuery.removedArtistSuffix {
                    result.append(cleanedQuery.query)
                }
            } else {
                Self.appendNovelWords(cleanedQuery.query, to: &result, allowsInflectionDeduplication: false)
            }
        }

        if !intent.activity.isEmpty {
            let resultContainsOnlyActivity = Self.activityPhrase(
                result.joined(separator: " "),
                represents: intent.activity
            )
            if resultContainsOnlyActivity {
                Self.appendNovelWords("music", to: &result)
            } else {
                let activity = result.isEmpty ? "\(intent.activity) music" : intent.activity
                Self.appendNovelWords(activity, to: &result)
            }
        }

        if !intent.version.isEmpty {
            let previousPartCount = result.count
            Self.appendNovelWords(intent.version, to: &result, allowsInflectionDeduplication: false)
            if result.count == previousPartCount,
               Self.groundingAddsVersionQualifier(
                   intent.version,
                   intentQuery: intent.query,
                   groundingQuery: groundingQuery
               )
            {
                result.append("\(intent.version) version")
            }
        }

        return result
    }

    private static func cleanQueryForAppending(
        _ query: String,
        artist: String,
        mood: String,
        activity: String,
        era: String
    ) -> (query: String, removedArtistSuffix: Bool) {
        var cleaned = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var removedArtistSuffix = false
        cleaned = cleaned.replacingOccurrences(
            of: #"\b([0-9]{2,4})['’]s\b"#,
            with: "$1s",
            options: .regularExpression
        )

        if !activity.isEmpty,
           MusicDiscoveryTaxonomy.containsActivityContext(cleaned),
           let activityClause = Self.trailingActivityClause(in: cleaned),
           Self.activityPhrase(activityClause.activity, represents: activity)
        {
            cleaned = activityClause.prefix
        }

        if !mood.isEmpty {
            let moodPhrases = [mood] + MusicDiscoveryTaxonomy.moodAliases(for: mood)
            for phrase in moodPhrases {
                let phrase = phrase.lowercased()
                let suffixes = [" for \(phrase)", " to \(phrase)"]
                if let suffix = suffixes.first(where: cleaned.hasSuffix) {
                    cleaned.removeLast(suffix.count)
                    break
                }
            }
        }

        if !era.isEmpty {
            let eraPhrases = [era, MusicDiscoveryTaxonomy.normalizedEra(era)] + Self.eraAliases(for: era)
            for phrase in eraPhrases {
                let phrase = phrase.lowercased()
                let suffixes = [
                    " from the \(phrase)", " from \(phrase)", " in the \(phrase)",
                    " in \(phrase)", " of the \(phrase)", " of \(phrase)",
                ]
                if let suffix = suffixes.first(where: cleaned.hasSuffix) {
                    cleaned.removeLast(suffix.count)
                    break
                }
            }
        }

        if !artist.isEmpty {
            let queryWithoutArtist = Self.removingArtistSuffix(from: cleaned, artist: artist)
            removedArtistSuffix = queryWithoutArtist != cleaned
            cleaned = queryWithoutArtist
        }

        let commandPrefixes = [
            "please play some ", "please play ", "play some ", "play ",
            "please queue some ", "please queue ", "queue some ", "queue ",
            "add some ", "add ",
        ]
        if let prefix = commandPrefixes.first(where: cleaned.hasPrefix) {
            cleaned.removeFirst(prefix.count)
        }

        for prefix in ["best of ", "greatest hits by ", "top songs by "] where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
            break
        }

        let words = cleaned.split(separator: " ")
        let skipWords: Set = [
            "songs", "music", "tracks", "hits", "hit", "best", "greatest", "top",
        ]
        let filtered = words.filter { !skipWords.contains(String($0)) }
        return (filtered.joined(separator: " "), removedArtistSuffix)
    }

    static func groundedIntent(
        _ intent: MusicIntent,
        groundingQuery: String? = nil
    ) -> MusicIntent {
        let groundingQuery = groundingQuery ?? intent.query
        guard !groundingQuery.isEmpty else { return intent }
        let requiresLexicalGrounding = MusicDiscoveryTaxonomy.requiresLexicalGrounding(for: groundingQuery)
        let roleGroundingQuery = MusicDiscoveryTaxonomy.queryExcludingExplicitTitle(groundingQuery, title: intent.query)

        // Guided generation can fill optional string fields with plausible but
        // unrequested values. Keep only modifiers represented in the subject.
        var genre = requiresLexicalGrounding
            ? self.groundedValue(
                intent.genre,
                in: roleGroundingQuery,
                aliases: MusicDiscoveryTaxonomy.genreAliases(for: intent.genre)
            )
            : intent.genre
        var mood = requiresLexicalGrounding
            ? self.groundedValue(
                intent.mood,
                in: roleGroundingQuery,
                aliases: MusicDiscoveryTaxonomy.moodAliases(for: intent.mood),
                allowsInflections: true
            )
            : intent.mood
        if !mood.isEmpty, !MusicDiscoveryTaxonomy.isKnownMood(mood) {
            mood = ""
        }
        let moodEvidence = self.matchedGroundingCandidates(
            intent.mood,
            aliases: MusicDiscoveryTaxonomy.moodAliases(for: intent.mood),
            in: roleGroundingQuery
        )
        let moodIsExplicit = !requiresLexicalGrounding || !moodEvidence.isEmpty
        if !genre.isEmpty,
           !mood.isEmpty,
           self.canonicalTokens(genre) == self.canonicalTokens(mood)
        {
            if MusicDiscoveryTaxonomy.genreKeywords.contains(self.canonicalTokens(genre).joined(separator: " ")) {
                mood = ""
            } else {
                genre = ""
            }
        }
        var activity = requiresLexicalGrounding
            ? self.groundedActivity(
                intent.activity,
                in: roleGroundingQuery
            )
            : intent.activity
        let activityEvidence = self.matchedGroundingCandidates(
            intent.activity,
            aliases: self.activityAliases(for: intent.activity),
            in: roleGroundingQuery
        )
        let activityIsExplicit = !requiresLexicalGrounding || (
            MusicDiscoveryTaxonomy.containsActivityContext(roleGroundingQuery) && !activityEvidence.isEmpty
        )
        let sharedEvidence = moodEvidence.intersection(activityEvidence)
        let hasOnlySharedEvidence = !sharedEvidence.isEmpty &&
            moodEvidence.subtracting(sharedEvidence).isEmpty &&
            activityEvidence.subtracting(sharedEvidence).isEmpty
        let moodAndActivityMatchExactly = self.canonicalTokens(mood) == self.canonicalTokens(activity)
        if !mood.isEmpty,
           !activity.isEmpty,
           MusicDiscoveryTaxonomy.moodAndActivityAreEquivalent(
               mood: mood,
               activity: activity,
               activityAliases: self.activityAliases(for: activity)
           ),
           moodAndActivityMatchExactly || hasOnlySharedEvidence || !moodIsExplicit || !activityIsExplicit
        {
            let canonicalActivity = self.canonicalTokens(activity)
            if MusicDiscoveryTaxonomy.activityKeywords.contains(where: { self.canonicalTokens($0) == canonicalActivity }) {
                mood = ""
            } else {
                activity = ""
            }
        }

        return MusicIntent(
            action: intent.action,
            query: intent.query,
            shuffleScope: intent.shuffleScope,
            artist: requiresLexicalGrounding ? self.groundedValue(intent.artist, in: roleGroundingQuery) : intent.artist,
            genre: genre,
            mood: mood,
            era: requiresLexicalGrounding
                ? self.groundedEra(intent.era, in: roleGroundingQuery)
                : intent.era,
            version: requiresLexicalGrounding
                ? self.groundedVersion(
                    intent.version,
                    intentQuery: intent.query,
                    groundingQuery: groundingQuery,
                    roleGroundingQuery: roleGroundingQuery,
                    constraints: [genre, mood, activity]
                )
                : intent.version,
            activity: activity
        )
    }
}

@available(macOS 26.0, *)
extension ContentSourceResolver {
    private static func matchedGroundingCandidates(
        _ value: String,
        aliases: [String],
        in query: String
    ) -> Set<String> {
        Set(([value] + aliases).compactMap { candidate in
            guard !Self.groundedValue(
                candidate,
                in: query,
                allowsInflections: true
            ).isEmpty else {
                return nil
            }
            return Self.canonicalTokens(candidate).joined()
        })
    }

    private static func groundedEra(_ era: String, in query: String) -> String {
        let grounded = Self.groundedValue(era, in: query, aliases: Self.eraAliases(for: era))
        if !grounded.isEmpty {
            return grounded
        }
        return MusicDiscoveryTaxonomy.year(in: query, representsEra: era) ? era : ""
    }

    static func groundedValue(
        _ value: String,
        in query: String,
        aliases: [String] = [],
        allowsInflections: Bool = false
    ) -> String {
        guard !value.isEmpty else { return "" }

        let queryWords = Self.normalizedTokens(query)
        let queryIdentityWords = Self.identityTokens(query)
        let candidates = [value] + aliases
        let isGrounded = candidates.contains { candidate in
            let unfilteredCandidateWords = Self.normalizedTokens(candidate)
            let candidateWords = unfilteredCandidateWords.filter { !MusicDiscoveryTaxonomy.groundingStopWords.contains($0) }
            if candidateWords.isEmpty {
                return Self.containsWordSequence(queryIdentityWords, Self.identityTokens(candidate))
            }
            if candidateWords.allSatisfy({ candidateWord in
                queryWords.contains { queryWord in
                    allowsInflections ? Self.tokensMatch(candidateWord, queryWord) : candidateWord == queryWord
                }
            }) {
                return true
            }

            let compactCandidate = candidateWords.map { token in
                allowsInflections ? Self.canonicalToken(token) : token
            }.joined()
            let comparisonQueryWords = queryWords.map { token in
                allowsInflections ? Self.canonicalToken(token) : token
            }
            if comparisonQueryWords.contains(compactCandidate) {
                return true
            }

            let candidateIdentityWords = Self.identityTokens(candidate).filter { !MusicDiscoveryTaxonomy.groundingStopWords.contains($0) }
            return !candidateIdentityWords.isEmpty && candidateIdentityWords.allSatisfy(queryIdentityWords.contains)
        }

        return isGrounded ? value : ""
    }

    private static func appendNovelWords(
        _ component: String,
        to parts: inout [String],
        allowsInflectionDeduplication: Bool = true
    ) {
        let words = component.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }

        var existingTokens = Set(Self.normalizedTokens(parts.joined(separator: " ")))
        let novelWords = words.filter { word in
            let normalizedWords = Self.normalizedTokens(word)
            guard !normalizedWords.isEmpty else { return false }
            let isDuplicate = normalizedWords.allSatisfy { normalizedWord in
                existingTokens.contains { existingWord in
                    allowsInflectionDeduplication
                        ? Self.tokensMatch(normalizedWord, existingWord)
                        : normalizedWord == existingWord
                }
            }
            if isDuplicate {
                return false
            }
            if allowsInflectionDeduplication {
                for normalizedWord in normalizedWords {
                    existingTokens.insert(normalizedWord)
                }
            }
            return true
        }
        guard !novelWords.isEmpty else { return }
        parts.append(novelWords.joined(separator: " "))
    }

    static func normalizedTokens(_ value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(
                of: #"\b([0-9]{2,4})['’]s\b"#,
                with: "$1s",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func canonicalTokens(_ value: String) -> [String] {
        self.normalizedTokens(value).map(self.canonicalToken)
    }

    private static func identityTokens(_ value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .compactMap { rawWord in
                let identityWord = rawWord
                    .replacingOccurrences(of: "!", with: "i")
                    .replacingOccurrences(of: "$", with: "s")
                    .replacingOccurrences(of: "@", with: "a")
                    .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
                return identityWord.isEmpty ? nil : identityWord
            }
    }

    private static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        self.canonicalToken(lhs) == self.canonicalToken(rhs)
    }

    private static func canonicalToken(_ token: String) -> String {
        switch token {
        case "energy", "energetic":
            return "energy"
        case "melancholic", "melancholy":
            return "melancholy"
        case "romance", "romantic":
            return "romance"
        case "sleep", "sleeping":
            return "sleep"
        case "remaster", "remastered":
            return "remaster"
        case "code", "coding":
            return "code"
        case "drive", "driving":
            return "drive"
        case "exercise", "exercising":
            return "exercise"
        default:
            break
        }

        if token.count > 4, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }

        if token.count > 5, token.hasSuffix("ing") {
            var stem = String(token.dropLast(3))
            if stem.count >= 3,
               let last = stem.last,
               stem.dropLast().last == last,
               !"aeiou".contains(last)
            {
                stem.removeLast()
            }
            return stem
        }

        let esEndings = ["ches", "shes", "sses", "xes", "zes"]
        if token.count > 4, esEndings.contains(where: token.hasSuffix) {
            return String(token.dropLast(2))
        }

        if token.count > 4,
           token.hasSuffix("s"),
           !token.hasSuffix("ss"),
           !token.hasSuffix("us"),
           !token.hasSuffix("is")
        {
            return String(token.dropLast())
        }

        return token
    }

    private static func eraAliases(for era: String) -> [String] {
        let lowered = era.lowercased()

        if lowered.contains("1960") {
            return ["60s", "sixties"]
        }
        if lowered.contains("1970") {
            return ["70s", "seventies"]
        }
        if lowered.contains("1980") {
            return ["80s", "eighties"]
        }
        if lowered.contains("1990") {
            return ["90s", "nineties"]
        }
        if lowered.contains("2000") {
            return ["2000s", "00s", "aughts", "noughties", "y2k"]
        }
        if lowered.contains("2010") {
            return ["2010s", "10s"]
        }
        if lowered.contains("2020") {
            return ["2020s", "20s"]
        }
        if lowered == "classic" {
            return ["oldies", "old school"]
        }
        return []
    }

    private static func versionAliases(for version: String) -> [String] {
        switch self.normalizedTokens(version).joined(separator: " ") {
        case "acoustic cover":
            ["acoustic covers"]
        case "cover":
            ["covers"]
        case "remix":
            ["remixes"]
        case "remastered":
            ["remaster"]
        default:
            []
        }
    }

    static func activityAliases(for activity: String) -> [String] {
        switch activity.lowercased() {
        case "study":
            ["studying"]
        case "workout":
            ["working out", "exercise", "exercising"]
        case "sleep":
            ["sleeping", "bedtime"]
        case "focus":
            ["working", "coding", "concentration"]
        case "drive", "driving":
            ["commute", "commuting"]
        case "run", "running":
            ["running", "workout"]
        case "cook", "cooking":
            ["cooking"]
        default:
            []
        }
    }

    private static func groundingAddsVersionQualifier(
        _ version: String,
        intentQuery: String,
        groundingQuery: String
    ) -> Bool {
        let candidates = [version] + Self.versionAliases(for: version)
        return candidates.contains { candidate in
            let candidateWords = Self.normalizedTokens(candidate)
            guard !candidateWords.isEmpty else { return false }

            let intentOccurrences = Self.sequenceOccurrenceCount(
                of: candidateWords,
                in: Self.normalizedTokens(intentQuery)
            )
            let groundingOccurrences = Self.sequenceOccurrenceCount(
                of: candidateWords,
                in: Self.normalizedTokens(groundingQuery)
            )
            return groundingOccurrences > intentOccurrences
        }
    }

    private static func groundedVersion(
        _ version: String,
        intentQuery: String,
        groundingQuery: String,
        roleGroundingQuery: String,
        constraints: [String]
    ) -> String {
        guard !version.isEmpty else { return "" }

        if self.groundingAddsVersionQualifier(
            version,
            intentQuery: intentQuery,
            groundingQuery: groundingQuery
        ) {
            return version
        }

        if self.normalizedTokens(version) == ["live"] {
            return self.liveVersionHasQualifierContext(
                in: intentQuery,
                constraints: constraints
            ) ? version : ""
        }

        return self.groundedValue(
            version,
            in: roleGroundingQuery,
            aliases: self.versionAliases(for: version),
            allowsInflections: true
        )
    }

    private static func liveVersionHasQualifierContext(in query: String, constraints: [String]) -> Bool {
        let words = Self.normalizedTokens(query)
        let contextWords: Set = [
            "acoustic", "album", "at", "concert", "cover", "covers", "from", "instrumental",
            "music", "performance", "recorded", "recording", "remix", "session", "show",
            "unplugged", "version",
        ]

        for index in words.indices where words[index] == "live" {
            let leadingWords = Array(words[..<index])
            let nextIndex = words.index(after: index)
            let trailingWords = nextIndex < words.endIndex ? Array(words[nextIndex...]) : []
            for constraint in constraints where !constraint.isEmpty {
                let constraintWords = Self.normalizedTokens(constraint)
                if trailingWords.starts(with: constraintWords) ||
                    leadingWords.suffix(constraintWords.count).elementsEqual(constraintWords)
                {
                    return true
                }
            }
            if index > words.startIndex, contextWords.contains(words[words.index(before: index)]) {
                return true
            }
            if index > words.startIndex {
                if MusicDiscoveryTaxonomy.genreKeywords.contains(where: { genre in
                    let genreWords = Self.normalizedTokens(genre)
                    return leadingWords.suffix(genreWords.count).elementsEqual(genreWords)
                }) {
                    return true
                }
            }

            if nextIndex < words.endIndex {
                if contextWords.contains(words[nextIndex]) {
                    return true
                }

                if MusicDiscoveryTaxonomy.genreKeywords.contains(where: {
                    trailingWords.starts(with: Self.normalizedTokens($0))
                }) {
                    return true
                }
            }
        }

        return false
    }

    private static func sequenceOccurrenceCount(of sequence: [String], in words: [String]) -> Int {
        guard !sequence.isEmpty, sequence.count <= words.count else { return 0 }

        return (0 ... (words.count - sequence.count)).reduce(into: 0) { count, start in
            if Array(words[start ..< start + sequence.count]) == sequence {
                count += 1
            }
        }
    }

    private static func containsNormalizedPhrase(_ normalizedValue: String, _ phrase: String) -> Bool {
        let valueWords = Self.canonicalTokens(normalizedValue)
        let phraseWords = Self.canonicalTokens(phrase)
        guard !phraseWords.isEmpty, phraseWords.count <= valueWords.count else { return false }

        for start in 0 ... (valueWords.count - phraseWords.count)
            where Array(valueWords[start ..< start + phraseWords.count]) == phraseWords
        {
            return true
        }
        return false
    }

    private static func containsWordSequence(_ valueWords: [String], _ phraseWords: [String]) -> Bool {
        guard !phraseWords.isEmpty, phraseWords.count <= valueWords.count else { return false }
        for start in 0 ... (valueWords.count - phraseWords.count)
            where Array(valueWords[start ..< start + phraseWords.count]) == phraseWords
        {
            return true
        }
        return false
    }

    private static func removingArtistSuffix(from query: String, artist: String) -> String {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let artistIdentity = Self.identityTokens(artist)
        guard !artistIdentity.isEmpty else { return query }

        for index in words.indices.reversed() where words[index] == "by" || words[index] == "from" {
            let suffixIdentity = Self.identityTokens(words[(index + 1)...].joined(separator: " "))
            let withoutArticle = suffixIdentity.first == "the" ? Array(suffixIdentity.dropFirst()) : suffixIdentity
            let artistWithoutArticle = artistIdentity.first == "the" ? Array(artistIdentity.dropFirst()) : artistIdentity
            if suffixIdentity == artistIdentity || withoutArticle == artistWithoutArticle {
                return words[..<index].joined(separator: " ")
            }
        }
        return query
    }

    private static func value(_ value: String, isRepresentedBy field: String) -> Bool {
        guard !field.isEmpty else { return false }
        let fieldWords = Self.canonicalTokens(field)
        return Self.canonicalTokens(value).allSatisfy(fieldWords.contains)
    }
}
