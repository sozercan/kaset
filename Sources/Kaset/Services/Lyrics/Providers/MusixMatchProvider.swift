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

            if let synced = Self.extractSyncedLyrics(from: html) {
                return .synced(synced)
            }

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

    static func extractSyncedLyrics(from html: String) -> SyncedLyrics? {
        guard let trackInfoData = Self.trackInfoData(from: html) else {
            return nil
        }

        let subtitleEntries = Self.subtitleEntries(from: trackInfoData)
        for entry in subtitleEntries {
            guard let body = Self.subtitleBody(in: entry),
                  let parsed = LRCParser.parse(body)
            else {
                continue
            }

            return SyncedLyrics(lines: parsed.lines, source: "MusixMatch")
        }

        return nil
    }

    static func extractLyrics(from html: String) -> String? {
        if let trackInfoData = trackInfoData(from: html),
           let lyricsBody = plainLyricsBody(from: trackInfoData)
        {
            let lyrics = HTMLLyricsExtractor.normalizeWhitespace(
                HTMLLyricsExtractor.decodeHTMLEntities(lyricsBody)
            )
            if !lyrics.isEmpty {
                return lyrics
            }
        }

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

private extension MusixMatchProvider {
    static func nextDataObject(from html: String) -> [String: Any]? {
        guard let data = HTMLLyricsExtractor.firstMatch(
            in: html,
            pattern: #"<script id="__NEXT_DATA__" type="application/json">(.*?)</script>"#
        ) else {
            return nil
        }

        guard let jsonData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData),
              let nextData = object as? [String: Any]
        else {
            return nil
        }

        return nextData
    }

    static func trackInfoData(from html: String) -> [String: Any]? {
        guard let nextData = nextDataObject(from: html),
              let props = nextData["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let data = pageProps["data"] as? [String: Any],
              let trackInfo = data["trackInfo"] as? [String: Any],
              let trackInfoData = trackInfo["data"] as? [String: Any]
        else {
            return nil
        }

        return trackInfoData
    }

    static func subtitleEntries(from trackInfoData: [String: Any]) -> [[String: Any]] {
        if let entries = trackInfoData["subtitle"] as? [[String: Any]] {
            return entries
        }

        if let entries = trackInfoData["subtitle"] as? [Any] {
            return entries.compactMap { $0 as? [String: Any] }
        }

        return []
    }

    static func subtitleBody(in entry: [String: Any]) -> String? {
        if let body = entry["subtitle_body"] as? String, !body.isEmpty {
            return body
        }

        if let body = entry["body"] as? String, !body.isEmpty {
            return body
        }

        if let body = entry["subtitleBody"] as? String, !body.isEmpty {
            return body
        }

        return nil
    }

    static func plainLyricsBody(from trackInfoData: [String: Any]) -> String? {
        guard let lyrics = trackInfoData["lyrics"] as? [String: Any],
              let body = lyrics["body"] as? String,
              !body.isEmpty
        else {
            return nil
        }

        return body
    }
}
