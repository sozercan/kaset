import Foundation

// MARK: - GeniusSearchResponse

private struct GeniusSearchResponse: Decodable {
    let response: Response

    struct Response: Decodable {
        let sections: [Section]
    }

    struct Section: Decodable {
        let type: String
        let hits: [Hit]
    }

    struct Hit: Decodable {
        let result: SongResult
    }

    struct SongResult: Decodable {
        let title: String
        let url: URL?
        let primaryArtist: Artist

        enum CodingKeys: String, CodingKey {
            case title
            case url
            case primaryArtist = "primary_artist"
        }
    }

    struct Artist: Decodable {
        let name: String
    }
}

// MARK: - LyricsGeniusProvider

final class LyricsGeniusProvider: LyricsProvider {
    let name = "LyricsGenius"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            guard let lyricsURL = try await self.searchLyricsPage(info: info) else {
                return .unavailable
            }

            let html = try await self.loadText(url: lyricsURL)
            let containers = HTMLLyricsExtractor.matches(
                in: html,
                pattern: #"<[^>]+data-lyrics-container=["']true["'][^>]*>(.*?)</[^>]+>"#
            )
            let lyrics = HTMLLyricsExtractor.normalizeWhitespace(
                containers
                    .map(HTMLLyricsExtractor.cleanLyricsHTML)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )

            guard !lyrics.isEmpty else { return .unavailable }
            return .plain(Lyrics(text: lyrics, source: "Source: \(self.name)"))
        } catch {
            return .unavailable
        }
    }

    private func searchLyricsPage(info: LyricsSearchInfo) async throws -> URL? {
        var components = URLComponents(string: "https://genius.com/api/search/multi")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "\(info.artist) \(info.title)"),
        ]

        guard let url = components?.url else { return nil }
        let data = try await self.loadData(url: url)
        let response = try JSONDecoder().decode(GeniusSearchResponse.self, from: data)

        let songHits = response.response.sections
            .filter { $0.type == "song" }
            .flatMap(\.hits)

        return songHits.first { hit in
            self.matches(hit.result, info: info)
        }?.result.url ?? songHits.first?.result.url
    }

    private func matches(_ result: GeniusSearchResponse.SongResult, info: LyricsSearchInfo) -> Bool {
        let title = result.title.normalizedLyricsSearchText
        let artist = result.primaryArtist.name.normalizedLyricsSearchText
        return title.contains(info.title.normalizedLyricsSearchText) ||
            info.title.normalizedLyricsSearchText.contains(title) ||
            artist.contains(info.artist.normalizedLyricsSearchText)
    }

    private func loadData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Kaset/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode
        else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    private func loadText(url: URL) async throws -> String {
        guard let text = try await String(data: self.loadData(url: url), encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return text
    }
}

private extension String {
    var normalizedLyricsSearchText: String {
        self.lowercased()
            .replacingOccurrences(of: #"(?i)\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9가-힣]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
