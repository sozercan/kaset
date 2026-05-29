import Foundation

// MARK: - LRCLibModel

struct LRCLibModel: Decodable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: TimeInterval?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

// MARK: - LRCLibProvider

final class LRCLibProvider: LyricsProvider {
    let name = "LRCLib"

    func search(info: LyricsSearchInfo) async -> LyricResult {
        var components = URLComponents(string: "https://lrclib.net/api/search")!

        var items = [
            URLQueryItem(name: "track_name", value: info.title),
            URLQueryItem(name: "artist_name", value: info.artist),
        ]

        if let album = info.album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }

        components.queryItems = items

        guard let url = components.url else { return .unavailable }

        var request = URLRequest(url: url)
        request.setValue("Kaset/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return .unavailable
            }

            let results = try JSONDecoder().decode([LRCLibModel].self, from: data)

            let validResults = results.filter {
                ($0.syncedLyrics != nil || $0.plainLyrics != nil) &&
                    ($0.instrumental == false || $0.instrumental == nil)
            }

            guard !validResults.isEmpty else { return .unavailable }

            let artistMatchedResults = validResults.filter {
                self.artistSimilarity(to: info.artist, against: $0.artistName ?? "") >= 0.8
            }
            let candidateResults = artistMatchedResults.isEmpty ? validResults : artistMatchedResults

            guard let bestMatch = self.closestDurationMatch(in: candidateResults, targetDuration: info.duration)
            else {
                return .unavailable
            }

            if let synced = bestMatch.syncedLyrics,
               let parsed = LRCParser.parse(synced)
            {
                return .synced(SyncedLyrics(lines: parsed.lines, source: self.name))
            }

            if let plain = bestMatch.plainLyrics, !plain.isEmpty {
                return .plain(Lyrics(text: plain, source: self.name))
            }

            return .unavailable
        } catch {
            return .unavailable
        }
    }

    private func closestDurationMatch(
        in results: [LRCLibModel],
        targetDuration: TimeInterval?
    ) -> LRCLibModel? {
        guard let first = results.first else {
            return nil
        }

        guard let targetDuration else {
            return first
        }

        return results.min(by: {
            let diffA = abs(($0.duration ?? 0) - targetDuration)
            let diffB = abs(($1.duration ?? 0) - targetDuration)
            return diffA < diffB
        })
    }

    private func artistSimilarity(to query: String, against candidate: String) -> Double {
        let normalizedQuery = Self.normalizeSearchText(query)
        let normalizedCandidate = Self.normalizeSearchText(candidate)
        if normalizedQuery.isEmpty || normalizedCandidate.isEmpty {
            return 0
        }

        if normalizedQuery == normalizedCandidate {
            return 1
        }

        if normalizedQuery.contains(normalizedCandidate) || normalizedCandidate.contains(normalizedQuery) {
            return 0.95
        }

        let queryParts = normalizedQuery.split(separator: "&").map { Self.normalizeSearchText(String($0)) }
        let candidateParts = normalizedCandidate.split(separator: "&").map { Self.normalizeSearchText(String($0)) }
        let scores = queryParts.flatMap { left in
            candidateParts.map { right in Self.tokenOverlapScore(left, right) }
        }

        return scores.max() ?? 0
    }

    private static func tokenOverlapScore(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(left.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        let rightTokens = Set(right.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else {
            return 0
        }

        let intersection = leftTokens.intersection(rightTokens).count
        let denominator = Double(max(leftTokens.count, rightTokens.count))
        return denominator == 0 ? 0 : Double(intersection) / denominator
    }

    private static func normalizeSearchText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"(?i)\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9가-힣&]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\S)&(?=\S)"#, with: " & ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
