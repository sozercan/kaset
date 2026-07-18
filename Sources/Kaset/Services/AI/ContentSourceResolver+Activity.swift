import Foundation

@available(macOS 26.0, *)
extension ContentSourceResolver {
    static func hasDistinctSearchSubject(in intent: MusicIntent) -> Bool {
        let genericWords: Set = [
            "a", "add", "an", "and", "by", "find", "for", "from", "in", "mix", "mixes",
            "music", "of", "play", "playlist", "playlists", "please", "queue", "search", "some",
            "song", "songs", "the", "to", "track", "tracks", "while", "with",
        ]
        let activityEvidenceTokens = Set(
            MusicDiscoveryTaxonomy.activityEvidencePhrases(in: intent.query)
                .flatMap(Self.canonicalTokens)
        )
        let subjectTokens = Self.canonicalTokens(intent.query).filter {
            !genericWords.contains($0) && !activityEvidenceTokens.contains($0)
        }
        guard !subjectTokens.isEmpty else { return false }

        let representedTokens = Set(
            [intent.genre, intent.mood, intent.activity, intent.era, intent.version]
                .flatMap(Self.canonicalTokens)
        )
        if !representedTokens.isEmpty,
           subjectTokens.allSatisfy(representedTokens.contains)
        {
            return false
        }

        let subject = subjectTokens.joined(separator: " ")
        if MusicDiscoveryTaxonomy.genreKeywords.contains(where: {
            Self.canonicalTokens($0) == subjectTokens
        }) || MusicDiscoveryTaxonomy.isKnownMood(subject) || MusicDiscoveryTaxonomy.containsEraReference(subject) {
            return false
        }

        return true
    }

    static func groundedActivity(_ activity: String, in query: String) -> String {
        guard !activity.isEmpty else { return "" }
        var activityEvidence = MusicDiscoveryTaxonomy.activityEvidencePhrases(in: query)
        if activityEvidence.isEmpty,
           let standaloneActivity = MusicDiscoveryTaxonomy.standaloneActivityPhrase(in: query)
        {
            activityEvidence = [standaloneActivity]
        }
        guard !activityEvidence.isEmpty else { return "" }

        let aliases = Self.activityAliases(for: activity)
        let isGrounded = activityEvidence.contains { evidence in
            !Self.groundedValue(
                activity,
                in: evidence,
                aliases: aliases,
                allowsInflections: true
            ).isEmpty
        }
        return isGrounded ? activity : ""
    }

    static func trailingActivityClause(in query: String) -> (prefix: String, activity: String)? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let markers: Set = ["for", "to", "while"]

        for index in words.indices.reversed() {
            let markerTokens = Self.normalizedTokens(words[index])
            guard markerTokens.count == 1, let marker = markerTokens.first, markers.contains(marker) else {
                continue
            }

            var activityStart = words.index(after: index)
            if marker == "for", activityStart < words.endIndex {
                let articleTokens = Self.normalizedTokens(words[activityStart])
                if articleTokens.count == 1,
                   let article = articleTokens.first,
                   ["a", "an", "the"].contains(article)
                {
                    activityStart = words.index(after: activityStart)
                }
            }
            guard activityStart < words.endIndex else { continue }

            return (
                words[..<index].joined(separator: " "),
                words[activityStart...].joined(separator: " ")
            )
        }

        return nil
    }

    static func activityPhrase(_ phrase: String, represents activity: String) -> Bool {
        let phraseTokens = Self.canonicalTokens(phrase)
        guard !phraseTokens.isEmpty else { return false }
        let compactPhrase = phraseTokens.joined()
        return ([activity] + Self.activityAliases(for: activity)).contains { candidate in
            let candidateTokens = Self.canonicalTokens(candidate)
            return candidateTokens == phraseTokens || candidateTokens.joined() == compactPhrase
        }
    }
}
