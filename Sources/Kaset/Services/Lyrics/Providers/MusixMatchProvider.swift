import Foundation

// MARK: - MusixMatchProvider

final class MusixMatchProvider: LyricsProvider {
    let name = "MusixMatch"

    private let session: URLSession
    private let api: MusixMatchAPI

    init(session: URLSession = .shared) {
        self.session = session
        self.api = MusixMatchAPI(session: session)
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            if let apiResult = try await self.searchViaMacroAPI(info: info) {
                return apiResult
            }

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

            return .plain(Lyrics(text: lyrics, source: self.name))
        } catch {
            return .unavailable
        }
    }

    private func searchViaMacroAPI(info: LyricsSearchInfo) async throws -> LyricResult? {
        let data = try await self.api.queryMacroSubtitles(info: info)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let macroCalls = Self.dictionaryValue(in: response, path: ["message", "body", "macro_calls"])
        else {
            return nil
        }

        guard let track = Self.track(from: macroCalls),
              track.trackId != 115_264_642
        else {
            return nil
        }

        let lyrics = Self.plainLyrics(from: macroCalls)
        let subtitle = Self.subtitleBody(from: macroCalls)

        if let subtitle, let parsed = LRCParser.parse(subtitle) {
            return .synced(SyncedLyrics(lines: parsed.lines, source: self.name))
        }

        if let lyrics, !lyrics.isEmpty {
            return .plain(Lyrics(text: lyrics, source: self.name))
        }

        return nil
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

    private static func track(from macroCalls: [String: Any]) -> MusixMatchTrack? {
        guard let track = dictionaryValue(
            in: macroCalls,
            path: ["matcher.track.get", "message", "body", "track"]
        ) else {
            return nil
        }

        let trackId = Self.intValue(track["track_id"])
        return MusixMatchTrack(trackId: trackId)
    }

    private static func plainLyrics(from macroCalls: [String: Any]) -> String? {
        guard let lyrics = dictionaryValue(
            in: macroCalls,
            path: ["track.lyrics.get", "message", "body", "lyrics"]
        ) else {
            return nil
        }

        if let body = lyrics["lyrics_body"] as? String, !body.isEmpty {
            return body
        }

        return nil
    }

    private static func subtitleBody(from macroCalls: [String: Any]) -> String? {
        guard let subtitleList = arrayValue(
            in: macroCalls,
            path: ["track.subtitles.get", "message", "body", "subtitle_list"]
        ) else {
            return nil
        }

        for item in subtitleList {
            guard let subtitleItem = item as? [String: Any],
                  let subtitle = subtitleItem["subtitle"] as? [String: Any],
                  let body = subtitle["subtitle_body"] as? String,
                  !body.isEmpty
            else {
                continue
            }

            return body
        }

        return nil
    }

    private static func dictionaryValue(in node: Any, path: [String]) -> [String: Any]? {
        guard let value = Self.value(in: node, path: path) as? [String: Any] else {
            return nil
        }

        return value
    }

    private static func arrayValue(in node: Any, path: [String]) -> [Any]? {
        guard let value = Self.value(in: node, path: path) as? [Any] else {
            return nil
        }

        return value
    }

    private static func value(in node: Any, path: [String]) -> Any? {
        guard let first = path.first else {
            return node
        }

        let remaining = Array(path.dropFirst())
        if let dictionary = node as? [String: Any] {
            if let child = dictionary[first] {
                return Self.value(in: child, path: remaining)
            }
        } else if let array = node as? [Any], let index = Int(first), array.indices.contains(index) {
            return Self.value(in: array[index], path: remaining)
        }

        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int {
            return value
        }
        if let value = value as? String {
            return Int(value) ?? 0
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return 0
    }

    static func extractSyncedLyrics(from html: String) -> SyncedLyrics? {
        guard let trackInfoData = Self.trackInfoData(from: html) else {
            return nil
        }

        for body in Self.subtitleBodies(in: trackInfoData) {
            guard let parsed = LRCParser.parse(body) else {
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
            guard let nextData = nextDataObject(from: html) else {
                return nil
            }
            return Self.findTrackInfoData(in: nextData)
        }

        return trackInfoData
    }

    static func subtitleBodies(in node: Any) -> [String] {
        var bodies: [String] = []

        if let dictionary = node as? [String: Any] {
            for key in ["subtitle", "subtitles", "subtitleBody", "subtitle_body", "body"] {
                if let body = dictionary[key] as? String,
                   !body.isEmpty,
                   Self.looksLikeLRC(body)
                {
                    bodies.append(body)
                }
            }

            for value in dictionary.values {
                bodies.append(contentsOf: Self.subtitleBodies(in: value))
            }
        } else if let array = node as? [Any] {
            for value in array {
                bodies.append(contentsOf: Self.subtitleBodies(in: value))
            }
        } else if let string = node as? String,
                  !string.isEmpty,
                  Self.looksLikeLRC(string)
        {
            bodies.append(string)
        }

        return bodies
    }

    static func looksLikeLRC(_ body: String) -> Bool {
        body.contains("[00:") || body.contains("[0")
    }

    static func plainLyricsBody(from trackInfoData: [String: Any]) -> String? {
        if let lyrics = trackInfoData["lyrics"] as? [String: Any],
           let body = lyrics["body"] as? String,
           !body.isEmpty
        {
            return body
        }

        for value in trackInfoData.values {
            if let body = Self.plainLyricsBody(in: value) {
                return body
            }
        }

        return nil
    }

    static func plainLyricsBody(in node: Any) -> String? {
        if let dictionary = node as? [String: Any] {
            if let lyrics = dictionary["lyrics"] as? [String: Any],
               let body = lyrics["body"] as? String,
               !body.isEmpty
            {
                return body
            }

            for value in dictionary.values {
                if let body = Self.plainLyricsBody(in: value) {
                    return body
                }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let body = Self.plainLyricsBody(in: value) {
                    return body
                }
            }
        }

        return nil
    }

    static func findTrackInfoData(in node: Any) -> [String: Any]? {
        if let dictionary = node as? [String: Any] {
            if let trackInfo = dictionary["trackInfo"] as? [String: Any],
               let trackInfoData = trackInfo["data"] as? [String: Any]
            {
                return trackInfoData
            }

            for value in dictionary.values {
                if let trackInfoData = Self.findTrackInfoData(in: value) {
                    return trackInfoData
                }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let trackInfoData = Self.findTrackInfoData(in: value) {
                    return trackInfoData
                }
            }
        }

        return nil
    }
}

// MARK: - MusixMatchAPI

private actor MusixMatchAPI {
    private struct SavedToken: Codable {
        let token: String
        let expires: Date
    }

    private let session: URLSession
    private let baseURL = URL(string: "https://apic-desktop.musixmatch.com/ws/1.1/")!
    private let appId = "web-desktop-app-v1.0"
    private let tokenStorageKey = "ytm:synced-lyrics:mxm:token"

    private var token: String?
    private var tokenExpiresAt: Date?
    private var cookie = "x-mxm-user-id="

    init(session: URLSession) {
        self.session = session
    }

    func queryMacroSubtitles(info: LyricsSearchInfo) async throws -> Data {
        try await self.reinit()

        var params: [String: String] = [
            "q_track": info.title,
            "q_artist": info.artist,
            "q_duration": String(Int(info.duration ?? 0)),
            "namespace": "lyrics_richsynched",
            "subtitle_format": "lrc",
        ]

        if let album = info.album, !album.isEmpty {
            params["q_album"] = album
        }

        return try await self.query(endpoint: "macro.subtitles.get", params: params)
    }

    private func reinit() async throws {
        if let token, !token.isEmpty, let tokenExpiresAt, tokenExpiresAt > Date() {
            return
        }

        if let saved = self.loadSavedToken(), saved.expires > Date() {
            self.token = saved.token
            self.tokenExpiresAt = saved.expires
            return
        }

        self.token = try await self.fetchToken()
        self.tokenExpiresAt = Date().addingTimeInterval(60)
        try self.saveToken(self.token)
    }

    private func query(endpoint: String, params: [String: String]) async throws -> Data {
        guard let token, !token.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        var components = URLComponents(url: self.baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "app_id", value: self.appId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "usertoken", value: token),
        ]
        queryItems.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = queryItems

        let (data, response) = try await self.load(url: components.url!)
        guard response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        if let statusCode = Self.statusCode(in: json), statusCode == 401 {
            self.token = nil
            self.tokenExpiresAt = nil
            return try await self.query(endpoint: endpoint, params: params)
        }

        return data
    }

    private func fetchToken() async throws -> String {
        var components = URLComponents(url: self.baseURL.appendingPathComponent("token.get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: self.appId),
        ]

        let (data, response) = try await self.load(url: components.url!, includeAuthCookie: true)
        guard response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = Self.value(in: json, path: ["message", "body", "user_token"]) as? String,
              !token.isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }

        return token
    }

    private func load(url: URL, includeAuthCookie: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("apic-desktop.musixmatch.com", forHTTPHeaderField: "Authority")
        if includeAuthCookie {
            request.setValue(self.cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"), !setCookie.isEmpty {
            self.cookie = setCookie
        }

        return (data, httpResponse)
    }

    private func loadSavedToken() -> SavedToken? {
        guard let data = UserDefaults.standard.data(forKey: self.tokenStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(SavedToken.self, from: data)
    }

    private func saveToken(_ token: String?) throws {
        guard let token else {
            UserDefaults.standard.removeObject(forKey: self.tokenStorageKey)
            return
        }

        let savedToken = SavedToken(token: token, expires: Date().addingTimeInterval(60))
        let data = try JSONEncoder().encode(savedToken)
        UserDefaults.standard.set(data, forKey: self.tokenStorageKey)
    }

    private static func statusCode(in json: [String: Any]) -> Int? {
        guard let message = json["message"] as? [String: Any],
              let header = message["header"] as? [String: Any],
              let statusCode = header["status_code"] as? Int
        else {
            return nil
        }

        return statusCode
    }

    private static func value(in node: Any, path: [String]) -> Any? {
        guard let first = path.first else {
            return node
        }

        let remaining = Array(path.dropFirst())
        if let dictionary = node as? [String: Any], let child = dictionary[first] {
            return Self.value(in: child, path: remaining)
        }

        if let array = node as? [Any], let index = Int(first), array.indices.contains(index) {
            return Self.value(in: array[index], path: remaining)
        }

        return nil
    }
}

// MARK: - MusixMatchTrack

private struct MusixMatchTrack {
    let trackId: Int
}
