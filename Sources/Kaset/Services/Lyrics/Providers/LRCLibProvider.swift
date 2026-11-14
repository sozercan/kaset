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
    static let providerName = "LRCLib"
    var name: String {
        Self.providerName
    }

    /// Duration difference beyond which the closest match is treated as a
    /// different recording of the song (a live version, a different cut).
    /// Metadata durations for the same recording differ by at most a few
    /// seconds between sources, so a large gap means different audio.
    static let closeDurationTolerance: TimeInterval = 5

    func search(info: LyricsSearchInfo) async -> LyricResult {
        var components = URLComponents(string: "https://lrclib.net/api/search")!

        let items = [
            URLQueryItem(name: "track_name", value: info.title),
            URLQueryItem(name: "artist_name", value: info.artist),
        ]

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

            // Filter out purely empty entries instrumentals
            let validParams = results.filter {
                ($0.syncedLyrics != nil || $0.plainLyrics != nil) &&
                    ($0.instrumental == false || $0.instrumental == nil)
            }

            guard !validParams.isEmpty else { return .unavailable }

            return Self.matchResult(from: validParams, info: info)
        } catch {
            return .unavailable
        }
    }

    /// Picks the result for a search: the entry whose duration is closest to
    /// the requested recording, its synced lyrics when available, else plain.
    /// With `requiresCloseDurationMatch`, a materially different duration means
    /// the closest match is a DIFFERENT RECORDING — its synced timings would
    /// highlight the wrong moments, so the result degrades to plain.
    static func matchResult(from validParams: [LRCLibModel], info: LyricsSearchInfo) -> LyricResult {
        // Find closest duration
        var bestMatch = validParams.first!
        if let targetDuration = info.duration {
            bestMatch = validParams.min(by: { a, b in
                let diffA = abs((a.duration ?? 0) - targetDuration)
                let diffB = abs((b.duration ?? 0) - targetDuration)
                return diffA < diffB
            }) ?? validParams.first!
        }

        // Wrong-recording guard: the closest match still belongs to a
        // different recording when its duration is materially off. Synced
        // lyrics from that recording highlight the wrong moments, so
        // degrade to the plain lyrics of the closest match.
        if info.requiresCloseDurationMatch,
           let targetDuration = info.duration,
           let matchDuration = bestMatch.duration,
           abs(matchDuration - targetDuration) > closeDurationTolerance
        {
            if let plain = bestMatch.plainLyrics {
                return .plain(Lyrics(text: plain, source: "Source: \(self.providerName)"))
            }
            return .unavailable
        }

        if let synced = bestMatch.syncedLyrics, let parsed = LRCParser.parse(synced) {
            let withSource = SyncedLyrics(lines: parsed.lines, source: Self.providerName)
            return .synced(withSource)
        } else if let plain = bestMatch.plainLyrics {
            return .plain(Lyrics(text: plain, source: "Source: \(Self.providerName)"))
        }

        return .unavailable
    }
}
