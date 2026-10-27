import CommonCrypto
import CryptoKit
import Foundation

// MARK: - NetEaseProvider

/// Lyrics provider backed by NetEase Cloud Music (music.163.com), the de-facto
/// lyrics library for CJK music. Keyless: search uses the public `api/search/pc`
/// endpoint with a synthesized anonymous client cookie; lyrics use the mobile
/// app's `eapi` endpoint (AES-128-ECB + MD5 with the app's public key), which is
/// the only shape that serves `yrc` word-level timings. Verified with
/// `swift run api-explorer lyrics-probe netease-eapi`.
///
/// eapi request shape (NeteaseCloudMusicApi reference):
/// - payload text = `{"id":…,header:{…},…}`, digest = MD5("nobody<path>use<text>md5forencrypt")
/// - data = `<path>-36cd479b6b5-<text>-36cd479b6b5-<digest>`, AES-128-ECB, uppercase hex
/// - POST `params=<hex>` to interface3.music.163.com
final class NetEaseProvider: LyricsProvider {
    let name = "NetEase"

    /// Public NetEase app key used by every eapi request.
    private static let eapiKey = Array("e82ckenh8dichen8".utf8)
    private static let eapiPath = "/api/song/lyric/v1"
    private static let eapiURL = URL(string: "https://interface3.music.163.com/eapi/song/lyric/v1")!
    private static let searchURLString = "https://music.163.com/api/search/pc"

    /// NetEase requires a recognizable client cookie set, not real session
    /// data; synthesized values are generated once per provider lifetime.
    private static let clientCookie: String = {
        func hex(_ count: Int) -> String {
            (0 ..< count).map { _ in String(format: "%x", Int.random(in: 0 ..< 16)) }.joined()
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return "os=pc; NMTID=\(hex(26)); _ntes_nnid=\(hex(32)),\(now); _ntes_nuid=\(hex(32))"
    }()

    /// Client header embedded in the eapi payload and echoed as the Cookie header.
    private static let eapiHeader: [String: String] = [
        "osver": "17.4.1",
        "deviceId": "iOS17.4.1",
        "os": "ios",
        "appver": "9.0.90",
        "versioncode": "140",
        "mobilename": "iPhone",
        "buildver": "1700000000",
        "resolution": "1170x2532",
        "__csrf": "",
        "channel": "",
        "requestId": "1700000000000_0001",
    ]

    func search(info: LyricsSearchInfo) async -> LyricResult {
        guard let songID = await Self.searchSongID(
            title: info.title,
            artist: info.artist,
            duration: info.duration
        ), let sections = await Self.fetchLyricSections(songID: songID) else {
            return .unavailable
        }

        // Word-level (yrc) wins over line-level (lrc) over plain.
        if let yrc = sections.yrc, let parsed = Self.parseYRC(yrc) {
            return .synced(SyncedLyrics(lines: parsed, source: self.name))
        }
        if let lrc = sections.lrc, let lines = Self.parseLyricBody(lrc) {
            return .synced(SyncedLyrics(lines: lines, source: self.name))
        }
        return .unavailable
    }

    // MARK: - Search

    private struct SearchResponse: Decodable {
        let result: SearchResult?

        struct SearchResult: Decodable {
            let songs: [Song]?
        }

        struct Song: Decodable {
            let id: Int
            let name: String
            let duration: Int?
        }
    }

    /// Picks the song whose name and artist best match and whose duration is
    /// closest; covers and live versions routinely outrank the original.
    private static func searchSongID(
        title: String,
        artist: String,
        duration: TimeInterval?
    ) async -> Int? {
        var components = URLComponents(string: searchURLString)!
        components.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("python-requests/2.32.3", forHTTPHeaderField: "User-Agent")
        request.setValue(self.clientCookie, forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let songs = decoded.result?.songs, !songs.isEmpty
        else {
            DiagnosticsLogger.api.warning("NetEase lyrics search failed or returned no songs")
            return nil
        }

        let candidates = songs.filter { song in
            self.titleContains(song.name, query: title)
        }
        let pool = candidates.isEmpty ? songs : candidates

        guard let duration else {
            return pool.first?.id
        }
        return pool.min {
            abs(($0.duration ?? 0) - Int(duration * 1000)) < abs(($1.duration ?? 0) - Int(duration * 1000))
        }?.id
    }

    /// Case-insensitive containment check with whitespace removed, so
    /// "(深情版)" style suffixes and spacing variants still match.
    private static func titleContains(_ songName: String, query: String) -> Bool {
        func squash(_ value: String) -> String {
            value.lowercased().components(separatedBy: .whitespaces).joined()
        }
        return squash(songName).contains(squash(query))
    }

    // MARK: - eapi lyric fetch

    private struct LyricSections {
        let lrc: String?
        let yrc: String?
    }

    private static func fetchLyricSections(songID: Int) async -> LyricSections? {
        let body: [String: Any] = [
            "id": "\(songID)",
            "cp": false,
            "lv": 0,
            "tv": 0,
            "rv": 0,
            "kv": 0,
            "yv": 0,
            "ytv": 0,
            "yrv": 0,
            "csrf_token": "",
            "header": eapiHeader,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body), let jsonText = String(bytes: jsonData, encoding: .utf8) else { return nil }
        let messageData = Data("nobody\(eapiPath)use\(jsonText)md5forencrypt".utf8)
        let digest = Insecure.MD5.hash(data: messageData)
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        let eapiData = "\(eapiPath)-36cd479b6b5-\(jsonText)-36cd479b6b5-\(digestHex)"

        guard let params = aesEapiEncryptHex(Data(eapiData.utf8)) else { return nil }

        var request = URLRequest(url: eapiURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(
            "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            self.eapiHeader.map { "\($0.0)=\($0.1)" }.joined(separator: "; "),
            forHTTPHeaderField: "Cookie"
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("params=\(params)".utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            DiagnosticsLogger.api.warning("NetEase eapi lyric fetch failed")
            return nil
        }

        func lyricString(_ key: String) -> String? {
            guard let section = json[key] as? [String: Any],
                  let lyric = section["lyric"] as? String,
                  !lyric.isEmpty
            else { return nil }
            return lyric
        }

        return LyricSections(lrc: lyricString("lrc"), yrc: lyricString("yrc"))
    }

    /// AES-128-ECB with PKCS7 padding, uppercase hex output.
    private static func aesEapiEncryptHex(_ data: Data) -> String? {
        let dataBytes = [UInt8](data)
        let paddedLength = ((dataBytes.count / 16) + 1) * 16
        var padded = dataBytes
        let pad = paddedLength - dataBytes.count
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))

        var out = [UInt8](repeating: 0, count: paddedLength)
        var outLength = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), UInt32(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            eapiKey, kCCKeySizeAES128, nil,
            &padded, padded.count,
            &out, out.count, &outLength
        )
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLength).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Parsers

    /// Parses yrc word-level lyrics: `[lineStart,lineDur](start,dur,0)syl(start,dur,0)syl…`.
    /// Metadata lines use a JSON shape and are skipped.
    static func parseYRC(_ raw: String) -> [SyncedLyricLine]? {
        let regex = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        var unmerged: [SyncedLyricLine] = []

        for line in raw.split(separator: "\n") {
            let nsLine = String(line)
            guard let regex,
                  let match = regex.firstMatch(
                      in: nsLine, options: [],
                      range: NSRange(nsLine.startIndex ..< nsLine.endIndex, in: nsLine)
                  )
            else { continue }

            let startMs = Int(nsLine[nsLine.index(nsLine.startIndex, offsetBy: match.range(at: 1).lowerBound) ..< nsLine.index(nsLine.startIndex, offsetBy: match.range(at: 1).upperBound)]) ?? 0
            let durationMs = Int(nsLine[nsLine.index(nsLine.startIndex, offsetBy: match.range(at: 2).lowerBound) ..< nsLine.index(nsLine.startIndex, offsetBy: match.range(at: 2).upperBound)]) ?? 0
            let remainder = String(nsLine[nsLine.index(nsLine.startIndex, offsetBy: match.range(at: 3).lowerBound)...])

            let syllables = self.parseYRCSyllables(remainder)
            guard !syllables.isEmpty else { continue }

            unmerged.append(
                SyncedLyricLine(
                    timeInMs: startMs,
                    duration: durationMs,
                    text: syllables.map(\.text).joined(),
                    words: syllables.map { TimedWord(timeInMs: $0.startMs, word: $0.text) }
                )
            )
        }

        guard !unmerged.isEmpty else { return nil }
        return unmerged.sorted { $0.timeInMs < $1.timeInMs }
    }

    private struct YRCSyllable {
        let startMs: Int
        let text: String
    }

    /// Extracts `(start,dur,0)syllable` pairs from the remainder of a yrc line.
    /// Splits at complete timing markers only, so lyric text containing
    /// parentheses (e.g. "(Yeah)") survives intact.
    private static func parseYRCSyllables(_ remainder: String) -> [YRCSyllable] {
        let regex = try? NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)"#)
        guard let regex else { return [] }

        let fullRange = NSRange(remainder.startIndex ..< remainder.endIndex, in: remainder)
        let markers = regex.matches(in: remainder, options: [], range: fullRange)

        var syllables: [YRCSyllable] = []
        for (index, match) in markers.enumerated() {
            func group(_ index: Int) -> String {
                let range = Range(match.range(at: index), in: remainder)!
                return String(remainder[range])
            }
            guard let start = Int(group(1)), let duration = Int(group(2)) else { continue }
            // Syllable text runs from this marker's end to the next marker;
            // internal spaces are meaningful, so no trimming.
            let textStart = match.range.upperBound
            let textEnd = index + 1 < markers.count ? markers[index + 1].range.lowerBound : fullRange.upperBound
            guard textStart <= textEnd,
                  let textRange = Range(NSRange(location: textStart, length: textEnd - textStart), in: remainder),
                  !textRange.isEmpty
            else { continue }
            let text = String(remainder[textRange]).trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { continue }
            syllables.append(YRCSyllable(startMs: start, text: text))
        }
        return syllables
    }

    /// Parses the two `lrc` shapes NetEase returns: classic LRC text, or the
    /// new JSON-per-line shape `{"t":ms,"c":[{"tx":"…"}]}`.
    static func parseLyricBody(_ raw: String) -> [SyncedLyricLine]? {
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           // JSON shape; fall through to the classic LRC parser when the JSON
           // path yields nothing, so a body mixing JSON metadata with LRC
           // lines still parses.
           let jsonLines = self.parseNetEaseJSONLyrics(raw), !jsonLines.isEmpty
        {
            return jsonLines
        }
        // Classic LRC: reuse the shared parser (it fills durations and merges
        // multi-timestamp lines), then drop the credit header lines NetEase
        // includes ("作词 : …", "Lyrics by: …").
        guard let parsed = LRCParser.parse(raw), !parsed.lines.isEmpty else { return nil }
        let creditPattern = try? NSRegularExpression(pattern: #"(作词|作曲|编曲|填词)\s*[:：]|(?i)lyrics\s*[:：]"#)
        let lines = parsed.lines.filter { line in
            guard let creditPattern else { return true }
            return creditPattern.firstMatch(
                in: line.text, options: [],
                range: NSRange(line.text.startIndex ..< line.text.endIndex, in: line.text)
            ) == nil
        }
        return lines.isEmpty ? nil : lines
    }

    private struct NetEaseJSONLine: Decodable {
        let t: Int?
        let c: [Chunk]?

        struct Chunk: Decodable {
            let tx: String?
        }
    }

    private static func parseNetEaseJSONLyrics(_ raw: String) -> [SyncedLyricLine]? {
        let decoder = JSONDecoder()
        var lines: [SyncedLyricLine] = []

        for line in raw.split(separator: "\n") {
            guard let entry = try? decoder.decode(NetEaseJSONLine.self, from: Data(line.utf8)) else { continue }
            let text = (entry.c ?? []).compactMap(\.tx).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let timeMs = entry.t, timeMs >= 0 else { continue }
            lines.append(SyncedLyricLine(timeInMs: timeMs, duration: 0, text: text, words: nil))
        }

        guard lines.count > 1 else { return nil }
        lines.sort { $0.timeInMs < $1.timeInMs }
        for index in lines.indices {
            let next = index + 1 < lines.count ? lines[index + 1].timeInMs : lines[index].timeInMs + 5000
            lines[index].duration = max(0, next - lines[index].timeInMs)
        }
        return lines
    }
}
