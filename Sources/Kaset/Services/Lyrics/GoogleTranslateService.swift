import Foundation

// MARK: - GoogleTranslateService

/// Keyless online lyrics translation via the unofficial Google Translate web
/// endpoint (`translate.googleapis.com/translate_a/single`, `client=gtx`). This
/// is the endpoint open-source YT Music clients use for lyric translations
/// (verified against better-lyrics' source and live with
/// `swift run api-explorer lyrics-probe translate`).
///
/// Batching: multiple lines are sent as one request joined by "\n"; the gtx
/// endpoint returns them with newlines escaped as literal "\n", which we decode
/// and split back. If the split count ever mismatches, callers fall back to
/// per-line requests.
enum GoogleTranslateService {
    private static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!
    /// The gtx endpoint is GET-only; keep each request's query under the URL
    /// length limits servers apply.
    private static let maxQueryLength = 3500

    /// Translates one batch of lines, returning results aligned with `texts`.
    /// Throws when the request fails entirely (offline, HTTP error).
    static func translateLines(_ texts: [String], target: String) async throws -> [String] {
        var results: [String] = []
        var index = 0
        while index < texts.count {
            var chunk: [String] = []
            var length = 0
            while index < texts.count, length + texts[index].count < self.maxQueryLength {
                chunk.append(texts[index])
                length += texts[index].count + 1
                index += 1
            }
            if chunk.isEmpty {
                // Single line longer than the cap: send it alone.
                chunk = [texts[index]]
                index += 1
            }
            try await results.append(contentsOf: self.translateBatch(chunk, target: target))
        }
        return results
    }

    private static func translateBatch(_ texts: [String], target: String) async throws -> [String] {
        let joined = texts.joined(separator: "\n")
        let translated = try await self.request(text: joined, target: target)
        let lines = self.decodeNewlines(translated)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard lines.count == texts.count else {
            DiagnosticsLogger.api.info("Google translate batch misaligned (\(lines.count) of \(texts.count)); falling back per line")
            var perLine: [String] = []
            for text in texts {
                try await perLine.append(self.request(text: text, target: target))
            }
            return perLine
        }
        return lines
    }

    /// Translates a block of plain (non-synced) lyrics, chunked by lines.
    static func translate(_ text: String, target: String) async throws -> String {
        let translated = try await self.translateLines(text.components(separatedBy: "\n"), target: target)
        return translated.joined(separator: "\n")
    }

    /// Maps a BCP-47 identifier (the settings value, e.g. "zh-Hans") to the
    /// language code the gtx endpoint accepts.
    static func targetCode(for identifier: String?) -> String {
        switch identifier {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case nil, ""?: "en"
        default: Locale.Language(identifier: identifier!).languageCode?.identifier ?? "en"
        }
    }

    private static func request(text: String, target: String) async throws -> String {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = json.first as? [[Any]]
        else {
            throw URLError(.cannotDecodeContentData)
        }

        return segments.compactMap { $0.first as? String }.joined()
    }

    /// gtx escapes newlines in the translated text as literal backslash-n.
    private static func decodeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
    }
}
