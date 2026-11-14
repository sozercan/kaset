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
    private static let endpoint = "https://translate.googleapis.com/translate_a/single"
    /// The gtx endpoint is GET-only; keep each request's query under the URL
    /// length limits servers apply.
    private static let maxQueryLength = 3500

    /// Translates one batch of lines, returning results aligned with `texts`.
    /// Throws when the request fails entirely (offline, HTTP error).
    static func translateLines(_ texts: [String], target: String) async throws -> [String] {
        var results: [String] = []
        var index = 0
        while index < texts.count {
            if try self.requestURL(text: texts[index], target: target).absoluteString.utf8.count > self.maxQueryLength {
                var translated = ""
                for fragment in try self.fragments(for: texts[index], target: target) {
                    translated += try await self.request(text: fragment, target: target)
                }
                results.append(translated)
                index += 1
                continue
            }
            var chunk: [String] = []
            while index < texts.count {
                let candidate = (chunk + [texts[index]]).joined(separator: "\n")
                guard try self.requestURL(text: candidate, target: target).absoluteString.utf8.count <= self.maxQueryLength else { break }
                chunk.append(texts[index])
                index += 1
            }
            try await results.append(contentsOf: self.translateBatch(chunk, target: target))
        }
        return results
    }

    /// Keeps batch responses aligned with source lines, retrying individual lines if necessary.
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
        case "zh-Hans", "zh-CN": "zh-CN"
        case "zh-Hant", "zh-TW": "zh-TW"
        case let identifier? where !identifier.isEmpty:
            Locale.Language(identifier: identifier).languageCode?.identifier ?? "en"
        default: "en"
        }
    }

    /// Constructs the same encoded URL used for measuring batches and sending requests.
    static func requestURL(text: String, target: String) throws -> URL {
        guard var components = URLComponents(string: self.endpoint) else { throw URLError(.badURL) }
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    /// Splits a long lyric line at character boundaries without exceeding the full encoded URL budget.
    static func fragments(for text: String, target: String) throws -> [String] {
        guard try self.requestURL(text: "", target: target).absoluteString.utf8.count < self.maxQueryLength else { throw URLError(.badURL) }
        var fragments: [String] = []
        var fragment = ""
        for character in text {
            let candidate = fragment + String(character)
            if try self.requestURL(text: candidate, target: target).absoluteString.utf8.count > self.maxQueryLength {
                guard !fragment.isEmpty else { throw URLError(.badURL) }
                fragments.append(fragment)
                fragment = String(character)
            } else {
                fragment = candidate
            }
        }
        if !fragment.isEmpty {
            fragments.append(fragment)
        }
        return fragments
    }

    /// Sends one bounded translation request and extracts translated segments.
    private static func request(text: String, target: String) async throws -> String {
        let url = try self.requestURL(text: text, target: target)
        guard url.absoluteString.utf8.count <= self.maxQueryLength else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
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
