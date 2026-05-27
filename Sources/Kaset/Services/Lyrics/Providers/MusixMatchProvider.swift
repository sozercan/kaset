import Foundation

// MARK: - MusixMatchProvider

final class MusixMatchProvider: LyricsProvider {
    let name = "MusixMatch"

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
            guard let lyrics = Self.extractLyrics(from: html), !lyrics.isEmpty else {
                return .unavailable
            }

            return .plain(Lyrics(text: lyrics, source: "Source: \(self.name)"))
        } catch {
            return .unavailable
        }
    }

    private func searchLyricsPage(info: LyricsSearchInfo) async throws -> URL? {
        let query = "\(info.artist) \(info.title)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? info.title
        guard let url = URL(string: "https://www.musixmatch.com/search/\(query)/tracks") else {
            return nil
        }

        let html = try await self.loadText(url: url)
        let paths = HTMLLyricsExtractor.matches(
            in: html,
            pattern: #"href=["'](/lyrics/[^"']+)["']"#
        )

        guard let path = paths.first else { return nil }
        return URL(string: "https://www.musixmatch.com\(path)")
    }

    static func extractLyrics(from html: String) -> String? {
        let blockPatterns = [
            #"<span[^>]+class=["'][^"']*lyrics__content__ok[^"']*["'][^>]*>(.*?)</span>"#,
            #"<p[^>]+class=["'][^"']*mxm-lyrics__content[^"']*["'][^>]*>(.*?)</p>"#,
            #"<div[^>]+class=["'][^"']*lyrics__content[^"']*["'][^>]*>(.*?)</div>"#,
        ]

        for pattern in blockPatterns {
            let lyrics = HTMLLyricsExtractor.normalizeWhitespace(
                HTMLLyricsExtractor.matches(in: html, pattern: pattern)
                    .map(HTMLLyricsExtractor.cleanLyricsHTML)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
            if !lyrics.isEmpty {
                return lyrics
            }
        }

        if let escapedBody = HTMLLyricsExtractor.firstMatch(
            in: html,
            pattern: #""body"\s*:\s*"((?:\\.|[^"\\])+)""#
        ) {
            let unescaped = escapedBody
                .replacingOccurrences(of: #"\\n"#, with: "\n")
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\/"#, with: "/")
            let lyrics = HTMLLyricsExtractor.normalizeWhitespace(HTMLLyricsExtractor.decodeHTMLEntities(unescaped))
            return lyrics.isEmpty ? nil : lyrics
        }

        return nil
    }

    private func loadData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Kaset/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

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
