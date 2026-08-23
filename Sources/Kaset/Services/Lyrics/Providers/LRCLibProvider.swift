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

            // Find closest duration
            var bestMatch = validParams.first!
            if let targetDuration = info.duration {
                bestMatch = validParams.min(by: { a, b in
                    let diffA = abs((a.duration ?? 0) - targetDuration)
                    let diffB = abs((b.duration ?? 0) - targetDuration)
                    return diffA < diffB
                }) ?? validParams.first!
            }

            if let synced = bestMatch.syncedLyrics, let parsed = LRCParser.parse(synced) {
                let withSource = SyncedLyrics(lines: parsed.lines, source: self.name)
                return .synced(withSource)
            } else if let plain = bestMatch.plainLyrics {
                return .plain(Lyrics(text: plain, source: "Source: \(self.name)"))
            }

            return .unavailable
        } catch {
            return .unavailable
        }
    }
}
