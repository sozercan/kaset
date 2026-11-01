import Foundation

// MARK: - BetterLyricsProvider

/// Lyrics provider backed by Better Lyrics' Unison crowdsourced API
/// (https://unison.betterlyrics.org). Keyless and registration-free.
///
/// Endpoints used (both lookups):
/// - `GET /lyrics?v=<videoId>` or `GET /lyrics?song=&artist=&[album=][&duration=]`
///   — highest-scored match, single-entry envelope. `/lyrics/search` is
///   deliberately avoided: it answers with a collection (`data: [...]`) that
///   this provider's decoder does not accept. Unison does server-side duration
///   matching within ±2s when `duration` is passed, which is exactly what
///   MV-mode needs to land on the right recording (e.g. a live version)
///   instead of the studio cut.
///
/// Response shapes:
///   { "success": true, "data": { id, videoId, song, artist, lyrics,
///     format, language, syncType, score, effectiveScore, voteCount,
///     confidence } }
///
/// `format` is `lrc`, `plain`, or `ttml`. LRC is parsed into timed lines
/// (synced); everything else degrades to plain lyrics. Wrong-recording guard:
/// when `requiresCloseDurationMatch` is set, the requested duration is sent to
/// the API so Unison narrows to a recording within tolerance; a missing or
/// empty result degrades to unavailable, letting the service fall through to
/// the next provider.
final class BetterLyricsProvider: LyricsProvider {
    let name = "BetterLyrics"

    private static let baseURL = URL(string: "https://unison.betterlyrics.org")!
    private static let durationToleranceSeconds: TimeInterval = 2

    /// Prefers an exact video match, or a duration-filtered recording match in MV mode.
    func search(info: LyricsSearchInfo) async -> LyricResult {
        // MV mode (different recording possible): ask Unison to match by
        // duration server-side so we get the recording actually playing.
        if info.requiresCloseDurationMatch, let duration = info.duration {
            return await Self.searchByMetadata(
                title: info.title,
                artist: info.artist,
                album: info.album,
                duration: duration,
                source: info.videoId
            )
        }

        // Normal playback: prefer the exact video match, then fall back to
        // metadata search.
        if !info.videoId.isEmpty,
           let result = await Self.searchByVideoId(info.videoId)
        {
            return result
        }

        return await Self.searchByMetadata(
            title: info.title,
            artist: info.artist,
            album: info.album,
            duration: nil,
            source: info.videoId
        )
    }

    // MARK: - Endpoints

    /// Looks up the highest-ranked lyrics explicitly associated with a YouTube video.
    private static func searchByVideoId(_ videoId: String) async -> LyricResult? {
        var components = URLComponents(url: baseURL.appendingPathComponent("lyrics"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: videoId)]

        guard let result = await Self.fetchEntry(url: components.url) else { return nil }
        return Self.lyricResult(from: result)
    }

    /// Uses metadata and optional recording duration when an exact video lookup is unsuitable.
    private static func searchByMetadata(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?,
        source _: String
    ) async -> LyricResult {
        // `/lyrics`, not `/lyrics/search`: both rank by score, but the search
        // route answers with a collection (`data: [...]`) while fetchEntry
        // decodes the single-entry envelope (`data: {...}`) that `/lyrics`
        // and `?v=` share. Verified against the unison API contract.
        var components = URLComponents(url: baseURL.appendingPathComponent("lyrics"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "song", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        if let album {
            items.append(URLQueryItem(name: "album", value: album))
        }
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        components.queryItems = items

        guard let result = await Self.fetchEntry(url: components.url) else {
            return .unavailable
        }
        return Self.lyricResult(from: result)
    }

    /// Decodes the single-result Unison envelope, rejecting unsuccessful or empty responses.
    private static func fetchEntry(url: URL?) async -> BetterLyricsEntry? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Kaset/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(BetterLyricsResponse.self, from: data),
              let entry = decoded.data
        else { return nil }
        return entry
    }

    // MARK: - Result conversion

    /// Converts supported timed formats and degrades other lyric formats to plain text.
    static func lyricResult(from entry: BetterLyricsEntry) -> LyricResult {
        let lyricsText = entry.lyrics
        guard !lyricsText.isEmpty else { return .unavailable }
        // Skip instrumental-only entries (better-lyrics behaviour).
        guard !LyricsSimilarity.isInstrumentalOnly(lyricsText) else { return .unavailable }

        switch entry.format {
        case "lrc":
            if let parsed = LRCParser.parse(lyricsText), !parsed.lines.isEmpty {
                // Re-source the parsed lines under this provider's name.
                let withSource = SyncedLyrics(
                    lines: parsed.lines.map {
                        SyncedLyricLine(
                            timeInMs: $0.timeInMs,
                            duration: $0.duration,
                            text: $0.text,
                            words: $0.words,
                            romanizedText: $0.romanizedText
                        )
                    },
                    source: Self.providerName
                )
                return .synced(withSource)
            }
            // LRC present but unparsable: fall through to plain.
            return .plain(Lyrics(text: Self.stripLRTimestamps(lyricsText), source: "Source: \(Self.providerName)"))
        case "plain", nil:
            return .plain(Lyrics(text: lyricsText, source: "Source: \(Self.providerName)"))
        case "ttml":
            return .plain(Lyrics(text: Self.stripTTMLTags(lyricsText), source: "Source: \(Self.providerName)"))
        default:
            return .plain(Lyrics(text: lyricsText, source: "Source: \(Self.providerName)"))
        }
    }

    private static let providerName = "BetterLyrics"

    /// Removes LRC timestamp tags so the text can be shown as plain lyrics.
    static func stripLRTimestamps(_ lrc: String) -> String {
        let regex = try? NSRegularExpression(pattern: #"\[[^\]]+\]"#)
        guard let regex else { return lrc }
        let cleaned = regex.stringByReplacingMatches(
            in: lrc, options: [], range: NSRange(lrc.startIndex ..< lrc.endIndex, in: lrc),
            withTemplate: ""
        )
        return cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Strips TTML XML tags, leaving the lyric text. Paragraph, division, and
    /// line-break tags become newlines so line boundaries survive, and XML
    /// text entities are decoded so the plain text reads as written.
    static func stripTTMLTags(_ ttml: String) -> String {
        var text = ttml
        if let blockRegex = try? NSRegularExpression(pattern: #"</?(?:p|div|br)\b[^>]*>"#) {
            text = blockRegex.stringByReplacingMatches(
                in: text, options: [], range: NSRange(text.startIndex ..< text.endIndex, in: text),
                withTemplate: "\n"
            )
        }
        if let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            text = tagRegex.stringByReplacingMatches(
                in: text, options: [], range: NSRange(text.startIndex ..< text.endIndex, in: text),
                withTemplate: ""
            )
        }
        text = Self.decodeXMLEntities(text)
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Decodes the XML entities that appear in TTML lyric text. `&` is
    /// decoded last so an escaped reference (`&lt;`) decodes only once.
    /// Restores escaped lyric text after TTML markup has been removed.
    private static func decodeXMLEntities(_ text: String) -> String {
        var decoded = text
        let named: [(entity: String, replacement: String)] = [
            ("\u{26}lt;", "<"),
            ("\u{26}gt;", ">"),
            ("\u{26}quot;", "\""),
            ("\u{26}apos;", "'"),
            ("\u{26}amp;", "&"),
        ]
        for entry in named {
            decoded = decoded.replacingOccurrences(of: entry.entity, with: entry.replacement)
        }

        let numericPattern = #"&#([xX][0-9a-fA-F]+|[0-9]+);"#
        guard let numericRegex = try? NSRegularExpression(pattern: numericPattern) else { return decoded }
        let matches = numericRegex.matches(
            in: decoded, options: [], range: NSRange(decoded.startIndex ..< decoded.endIndex, in: decoded)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: decoded) else { continue }
            let digits = decoded[range].dropFirst(2).dropLast()
            let scalarValue: UInt32? = if digits.first == "x" || digits.first == "X" {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits, radix: 10)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                decoded.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return decoded
    }
}

// MARK: - BetterLyricsResponse

struct BetterLyricsResponse: Decodable {
    let success: Bool
    let data: BetterLyricsEntry?
}

// MARK: - BetterLyricsEntry

struct BetterLyricsEntry: Decodable {
    let id: Int
    let videoId: String
    let song: String
    let artist: String
    let lyrics: String
    let format: String?
    let language: String?
    let syncType: String?
    let score: Int?
    let effectiveScore: Double?
    let voteCount: Int?
    let confidence: String?
}
