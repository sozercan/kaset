import Foundation

// MARK: - KuGouProvider

/// Lyrics provider backed by KuGou, the provider OuterTune and Metrolist ship
/// for CJK coverage. Keyless and line-level (KRC word timings are encrypted, so
/// all open-source clients use the `fmt=lrc` download). Verified with
/// `swift run api-explorer lyrics-probe kugou`.
final class KuGouProvider: LyricsProvider {
    let name = "KuGou"

    private static let searchURL = URL(string: "https://mobileservice.kugou.com/api/v3/search/song")!
    private static let lyricSearchURL = URL(string: "https://lyrics.kugou.com/search")!
    private static let downloadURL = URL(string: "https://lyrics.kugou.com/download")!
    private static let userAgent = "python-requests/2.32.3"
    private static let durationToleranceSeconds = 8

    /// Downloads lyrics after validating the requested recording duration.
    func search(info: LyricsSearchInfo) async -> LyricResult {
        guard let candidate = await Self.searchCandidate(
                  title: info.title,
                  artist: info.artist,
                  duration: info.duration
              ),
              let lrc = await Self.downloadLRC(id: candidate.id, accessKey: candidate.accessKey),
              let parsed = LRCParser.parse(lrc)
        else {
            return .unavailable
        }

        return .synced(SyncedLyrics(lines: parsed.lines, source: self.name))
    }

    private struct LyricCandidate {
        let id: String
        let accessKey: String
    }

    // MARK: - Response models

    private struct SongSearchResponse: Decodable {
        let data: DataSection?

        struct DataSection: Decodable {
            let info: [Song]?
        }

        struct Song: Decodable {
            let hash: String?
            let duration: Int?
        }
    }

    private struct LyricSearchResponse: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let id: String
            let accesskey: String
        }
    }

    private struct DownloadResponse: Decodable {
        let status: Int?
        let content: String?
    }

    // MARK: - Flow

    /// Mirrors the OuterTune/Metrolist flow: search songs, pick the first whose
    /// duration is within tolerance, then fall back to a keyword lyric search.
    private static func searchCandidate(
        title: String,
        artist: String,
        duration: TimeInterval?
    ) async -> LyricCandidate? {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "version", value: "9108"),
            URLQueryItem(name: "plat", value: "0"),
            URLQueryItem(name: "pagesize", value: "8"),
            URLQueryItem(name: "showtype", value: "0"),
            URLQueryItem(name: "keyword", value: "\(title) - \(artist)"),
        ]

        if let songs = await fetchJSON(SongSearchResponse.self, url: components.url!)?.data?.info {
            for song in songs {
                if let hash = song.hash,
                   let duration,
                   let songDuration = song.duration,
                   abs(songDuration - Int(duration)) <= durationToleranceSeconds,
                   let candidate = await candidateByHash(hash)
                {
                    return candidate
                }
            }
        }

        guard let duration else { return nil }
        var lyricComponents = URLComponents(url: lyricSearchURL, resolvingAgainstBaseURL: false)!
        lyricComponents.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "duration", value: String(Int(duration) * 1000)),
            URLQueryItem(name: "keyword", value: "\(title) - \(artist)"),
        ]
        if let response = await fetchJSON(LyricSearchResponse.self, url: lyricComponents.url!) {
            return response.candidates?.first.map {
                LyricCandidate(id: $0.id, accessKey: $0.accesskey)
            }
        }
        return nil
    }

    /// Finds a downloadable lyric entry for an already matched recording hash.
    private static func candidateByHash(_ hash: String) async -> LyricCandidate? {
        var components = URLComponents(url: lyricSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "hash", value: hash),
        ]
        if let response = await fetchJSON(LyricSearchResponse.self, url: components.url!) {
            return response.candidates?.first.map {
                LyricCandidate(id: $0.id, accessKey: $0.accesskey)
            }
        }
        return nil
    }

    /// Decodes the provider’s base64 LRC payload and removes metadata credits.
    private static func downloadLRC(id: String, accessKey: String) async -> String? {
        var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "accesskey", value: accessKey),
        ]

        guard let response = await fetchJSON(DownloadResponse.self, url: components.url!),
              response.status == 200,
              let content = response.content,
              let decoded = Data(base64Encoded: content),
              let lrc = String(data: decoded, encoding: .utf8)
        else {
            DiagnosticsLogger.api.warning("KuGou lyrics download failed")
            return nil
        }

        return Self.stripMetadataLines(lrc)
    }

    /// Removes the "作词/作曲/编曲" credit header and trailing credits that
    /// KuGou includes in many LRC payloads (the OuterTune/Metrolist normalize
    /// step, reduced to the header/tail cut).
    private static func stripMetadataLines(_ lrc: String) -> String {
        let timedPattern = try? NSRegularExpression(pattern: #"^\[\d+:\d+([.,]\d+)?\]"#)
        let creditPattern = try? NSRegularExpression(pattern: #"(作词|作曲|编曲|填词)\s*[:：]|(?i)lyrics\s*[:：]"#)
        guard let timedPattern else { return lrc }

        /// Distinguishes lyric rows from metadata before trimming the response boundaries.
        func isTimed(_ line: String) -> Bool {
            timedPattern.firstMatch(
                in: line, options: [],
                range: NSRange(line.startIndex ..< line.endIndex, in: line)
            ) != nil
        }

        var lines = lrc.components(separatedBy: .newlines)

        // Header: drop leading lines before the first timed line.
        while let first = lines.first, !isTimed(first) {
            lines.removeFirst()
        }
        // Tail: drop lines after the last timed line.
        while let last = lines.last, !isTimed(last) {
            lines.removeLast()
        }

        // Drop remaining timed credit lines ("作词 :", "作曲 :", etc.).
        if let creditPattern {
            lines = lines.filter { line in
                creditPattern.firstMatch(
                    in: line, options: [],
                    range: NSRange(line.startIndex ..< line.endIndex, in: line)
                ) == nil
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Downloads one provider response with a bounded timeout so other providers are not delayed.
    private static func fetchJSON<T: Decodable>(_: T.Type, url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }
}
