import CommonCrypto
import Foundation

// MARK: - Third-Party Lyrics Probes

// Read-only probes for keyless word/syllable-synced lyrics providers and the
// keyless translation endpoint, so response shapes are verified before the
// app-side providers are written (AGENTS.md API Discovery rule).
//
// Commands:
//   lyrics-probe musixmatch-token    - Fetch a keyless Musixmatch usertoken
//   lyrics-probe musixmatch <query>  - Search Musixmatch and dump richsync shape
//   lyrics-probe netease <query>     - Search NetEase and dump yrc/klyric/lrc shape
//   lyrics-probe translate <text> [targetLang]
//
// All requests are GET-only and never mutate account data. Tokens are printed
// REDACTED.

private let musixmatchBaseURL = "https://apic-desktop.musixmatch.com/ws/1.1/"
private let musixmatchAppID = "web-desktop-app-v1.0"
private let musixmatchUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/131.0.0.0 Safari/537.36"

private let neteaseUserAgent = "python-requests/2.32.3"

/// Synthesized anonymous client cookie: the endpoints only require a
/// recognizable client cookie set (Sing-Along probing), not real session data.
private let neteaseCookie: String = {
    func hex(_ count: Int) -> String {
        (0 ..< count).map { _ in String(format: "%x", Int.random(in: 0 ..< 16)) }.joined()
    }
    let now = Int(Date().timeIntervalSince1970 * 1000)
    return "os=pc; NMTID=\(hex(26)); _ntes_nnid=\(hex(32)),\(now); _ntes_nuid=\(hex(32))"
}()

// MARK: Musixmatch web signed flow (Strvm/musicxmatch-api shape)

//
// No usertoken at all: the signing secret is scraped from musixmatch.com's own
// web app bundle each session, and requests go to www.musixmatch.com/ws/1.1/
// signed with HMAC-SHA256 over "<path>?<query><YYYYMMDD>".

private nonisolated(unsafe) var musixmatchWebSecret: String?

private func fetchMusixmatchWebSecret() async -> String? {
    if let musixmatchWebSecret {
        return musixmatchWebSecret
    }

    guard let searchURL = URL(string: "https://www.musixmatch.com/search") else { return nil }
    var searchRequest = URLRequest(url: searchURL)
    searchRequest.setValue(musixmatchUserAgent, forHTTPHeaderField: "User-Agent")
    searchRequest.setValue("mxm_bab=AB", forHTTPHeaderField: "Cookie")

    do {
        let (data, _) = try await URLSession.shared.data(for: searchRequest)
        let html = String(decoding: data, as: UTF8.self)
        let scriptPattern = try NSRegularExpression(pattern: #"/_next/static/[^"']+\.js"#)
        let scriptMatches = scriptPattern.matches(
            in: html, options: [],
            range: NSRange(html.startIndex ..< html.endIndex, in: html)
        )
        let scriptURLs = scriptMatches.compactMap { Range($0.range, in: html).map { String(html[$0]) } }
        guard let appURL = scriptURLs.last(where: { $0.contains("_app") }) else {
            print("❌ _app script URL not found; page size \(html.count), \(scriptURLs.count) scripts")
            for url in scriptURLs.prefix(12) {
                print("  ", url)
            }
            return nil
        }
        let jsURL = appURL.hasPrefix("http") ? appURL : "https://www.musixmatch.com\(appURL)"

        guard let jsEndpoint = URL(string: jsURL) else { return nil }
        var jsRequest = URLRequest(url: jsEndpoint)
        jsRequest.setValue(musixmatchUserAgent, forHTTPHeaderField: "User-Agent")
        let (jsData, jsResponse) = try await URLSession.shared.data(for: jsRequest)
        let js = String(decoding: jsData, as: UTF8.self)
        print("app bundle: \(jsURL) → HTTP \((jsResponse as? HTTPURLResponse)?.statusCode ?? -1), \(js.count) bytes")

        // from\("(.*?)"\.split — reversed base64 payload holding the HMAC key
        let pattern = try NSRegularExpression(pattern: #"from\(\s*"(.*?)"\s*\.split"#)
        let range = NSRange(js.startIndex ..< js.endIndex, in: js)
        guard let match = pattern.firstMatch(in: js, options: [], range: range),
              let encodedRange = Range(match.range(at: 1), in: js)
        else {
            print("❌ encoded secret not found in _app bundle (js size \(js.count))")
            // Diagnose: does the bundle contain the from( pattern at all?
            let fromMatches = try NSRegularExpression(pattern: #"from\("#).matches(
                in: js, options: [], range: range
            )
            print("from( occurrences: \(fromMatches.count); .split occurrences: \(js.components(separatedBy: ".split").count - 1)")
            return nil
        }

        let encoded = String(js[encodedRange])
        let reversed = String(encoded.reversed())
        guard let decodedData = Data(base64Encoded: reversed),
              let secret = String(data: decodedData, encoding: .utf8)
        else {
            print("❌ could not decode secret")
            return nil
        }

        musixmatchWebSecret = secret
        print("✅ Got web secret: \(redacted(secret))")
        return secret
    } catch {
        print("❌ \(error.localizedDescription)")
        return nil
    }
}

private func musixmatchWebRequest(method: String, query: String) async {
    guard let secret = await fetchMusixmatchWebSecret() else { return }

    // Python urllib.parse.quote semantics (safe="/"), space stays %20-encoded
    // upstream and is swapped to '+' before signing, matching the reference client.
    let signedQuery = query.replacingOccurrences(of: "%20", with: "+")
    let url = "https://www.musixmatch.com/ws/1.1/\(method)?\(signedQuery)"

    let day = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }()

    var hmacData = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    var key = [UInt8](secret.utf8)
    var message = [UInt8]((url + day).utf8)
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), &key, key.count, &message, message.count, &hmacData)

    let signature = Data(hmacData).base64EncodedString()
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))!

    guard let requestURL = URL(string: url + "&signature=\(signature)&signature_protocol=sha256") else { return }
    var request = URLRequest(url: requestURL)
    request.setValue(musixmatchUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.musixmatch.com/", forHTTPHeaderField: "Referer")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        print("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        print(prettyJSON(data))
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

private nonisolated(unsafe) var musixmatchSessionToken: String?

private func redacted(_ value: String?) -> String {
    value == nil || value!.isEmpty ? "<nil>" : "REDACTED"
}

private func prettyJSON(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else {
        return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: pretty, as: UTF8.self)
}

/// Fetches (and caches per session) a keyless Musixmatch desktop-app usertoken.
private func fetchMusixmatchToken() async -> String? {
    if let musixmatchSessionToken {
        print("✅ Reusing cached token: \(redacted(musixmatchSessionToken))")
        return musixmatchSessionToken
    }

    var components = URLComponents(string: musixmatchBaseURL + "token.get")!
    components.queryItems = [
        URLQueryItem(name: "user_language", value: "en"),
        URLQueryItem(name: "app_id", value: musixmatchAppID),
    ]

    var request = URLRequest(url: components.url!)
    request.setValue(musixmatchUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("x-mxm-user-id=", forHTTPHeaderField: "Cookie")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        print("HTTP \(http.statusCode)")

        // URLSession stores the Set-Cookie (AWSELB) automatically for later calls.

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let header = message["header"] as? [String: Any],
              let status = header["status_code"] as? Int
        else {
            print(prettyJSON(data))
            return nil
        }

        guard status == 200,
              let body = message["body"] as? [String: Any],
              let token = body["user_token"] as? String,
              token != "UpgradeOnlyUpgradeOnlyUpgradeOnlyUpgradeOnly"
        else {
            print("status_code \(status), hint: \(header["hint"] ?? "<none>")")
            print(prettyJSON(data))
            return nil
        }

        musixmatchSessionToken = token
        print("✅ Got token: \(redacted(token))")
        return token
    } catch {
        print("❌ \(error.localizedDescription)")
        return nil
    }
}

/// Searches Musixmatch, then dumps the richsync/subtitle/lyrics body shapes.
private func probeMusixmatch(query: [String]) async {
    guard let token = await fetchMusixmatchToken() else { return }

    let track = query.count >= 2 ? query[1] : "Shape of You"
    let artist = query.count >= 3 ? query[2] : "Ed Sheeran"

    var components = URLComponents(string: musixmatchBaseURL + "track.search")!
    components.queryItems = [
        URLQueryItem(name: "app_id", value: musixmatchAppID),
        URLQueryItem(name: "usertoken", value: token),
        URLQueryItem(name: "q_track", value: track),
        URLQueryItem(name: "q_artist", value: artist),
        URLQueryItem(name: "page_size", value: "5"),
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "s_track_rating", value: "asc"),
    ]

    var request = URLRequest(url: components.url!)
    request.setValue(musixmatchUserAgent, forHTTPHeaderField: "User-Agent")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("❌ HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let trackList = body["track_list"] as? [[String: Any]],
              let first = trackList.first?["track"] as? [String: Any]
        else {
            print(prettyJSON(data))
            return
        }

        let trackID = first["track_id"]
        let commonTrackID = first["commontrack_id"]
        print("track_id: \(trackID ?? "<nil>"), commontrack_id: \(commonTrackID ?? "<nil>")")
        print("has_richsync: \(first["has_richsync"] ?? "<nil>"), has_subtitles: \(first["has_subtitles"] ?? "<nil>")")

        // macro.subtitles.get returns all bodies in one call when the desktop-app
        // token is used (namespace=lyrics_richsynched adds track.richsync.get).
        // Mirrors pear-desktop's provider shape exactly: plain query params, no
        // signature, Chrome UA, x-mxm-user-id= cookie.
        var macroQuery = [
            "app_id=\(musixmatchAppID)",
            "format=json",
            "usertoken=\(token)",
            "q_track=\(track)",
            "q_artist=\(artist)",
            "q_duration=\(query.count >= 5 ? query[4] : "0")",
            "user_language=en",
            "namespace=lyrics_richsynched",
            "subtitle_format=lrc",
        ]
        if let album = query.count >= 4 ? query[3] : nil {
            macroQuery.insert("q_album=\(album)", at: 5)
        }
        let macroQueryEncoded = macroQuery
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .joined(separator: "&")
        guard let macroURL = URL(string: musixmatchBaseURL + "macro.subtitles.get?" + macroQueryEncoded) else {
            print("❌ Could not build request")
            return
        }
        var macroRequest = URLRequest(url: macroURL)
        macroRequest.setValue(musixmatchUserAgent, forHTTPHeaderField: "User-Agent")

        let (macroData, macroResponse) = try await URLSession.shared.data(for: macroRequest)
        print("\n=== macro.subtitles.get: HTTP \((macroResponse as? HTTPURLResponse)?.statusCode ?? -1) ===")
        guard let macroJSON = try? JSONSerialization.jsonObject(with: macroData) as? [String: Any],
              let macroMessage = macroJSON["message"] as? [String: Any],
              let macroHeader = macroMessage["header"] as? [String: Any],
              let macroStatus = macroHeader["status_code"] as? Int
        else {
            print(prettyJSON(macroData))
            return
        }
        print("status_code: \(macroStatus)")
        guard let macroBody = macroMessage["body"] as? [String: Any],
              let macroCalls = macroBody["macro_calls"] as? [String: Any]
        else {
            print(prettyJSON(macroData))
            return
        }
        print("macro_calls keys: \(macroCalls.keys.sorted())")

        // Word/syllable level: track.richsync.get body
        if let richCall = macroCalls["track.richsync.get"] as? [String: Any],
           let richMessage = richCall["message"] as? [String: Any],
           let richBody = richMessage["body"] as? [String: Any],
           let richsync = richBody["richsync"] as? [String: Any],
           let richsyncBody = richsync["richsync_body"] as? String,
           let lines = try? JSONSerialization.jsonObject(with: Data(richsyncBody.utf8)) as? [[String: Any]]
        {
            print("\nrichsync lines: \(lines.count)")
            for line in lines.prefix(2) {
                let keys = line.keys.sorted().joined(separator: ",")
                print("line keys: [\(keys)]")
                if let l = line["l"] as? [[String: Any]], let firstWord = l.first {
                    let wordKeys = firstWord.keys.sorted().joined(separator: ",")
                    print("  word keys: [\(wordKeys)]")
                    print("  ts: \(line["ts"] ?? "<nil>"), te: \(line["te"] ?? "<nil>"), first word: \(firstWord)")
                    if l.count > 1 {
                        print("  second word: \(l[1])")
                    }
                }
            }
        } else {
            print("richsync: <absent>")
            if let richCall = macroCalls["track.richsync.get"] as? [String: Any],
               let richMessage = richCall["message"] as? [String: Any],
               let richHeader = richMessage["header"] as? [String: Any]
            {
                print("richsync status: \(richHeader)")
            }
        }

        // Line level: track.subtitles.get body
        if let subtitleCall = macroCalls["track.subtitles.get"] as? [String: Any],
           let subtitleMessage = subtitleCall["message"] as? [String: Any],
           let subtitleBody = subtitleMessage["body"] as? [String: Any],
           let subtitleList = subtitleBody["subtitle_list"] as? [[String: Any]],
           let firstSubtitle = subtitleList.first?["subtitle"] as? [String: Any],
           let subtitleBodyText = firstSubtitle["subtitle_body"] as? String
        {
            print("\nsubtitle_body (first 3 lines):")
            for line in subtitleBodyText.split(separator: "\n").prefix(3) {
                print("  \(line)")
            }
        } else {
            print("\nsubtitles: <absent>")
        }
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

/// Searches NetEase, then dumps the lyric endpoint's yrc/klyric/lrc shapes.
private func probeNetEase(query: [String]) async {
    let keywords = query.count >= 2 ? query[1] : "晴天 周杰伦"

    var searchComponents = URLComponents(string: "https://music.163.com/api/search/pc")!
    searchComponents.queryItems = [
        URLQueryItem(name: "s", value: keywords),
        URLQueryItem(name: "type", value: "1"),
        URLQueryItem(name: "limit", value: "5"),
    ]
    var searchRequest = URLRequest(url: searchComponents.url!)
    searchRequest.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")
    searchRequest.setValue(neteaseCookie, forHTTPHeaderField: "Cookie")
    searchRequest.setValue("https://music.163.com", forHTTPHeaderField: "Referer")

    do {
        let (data, response) = try await URLSession.shared.data(for: searchRequest)
        guard let http = response as? HTTPURLResponse else { return }
        print("search HTTP \(http.statusCode)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              var songID = songs.first?["id"] as? Int,
              let first = songs.first
        else {
            print(prettyJSON(data))
            return
        }

        print("first song: id=\(songID), name=\(first["name"] ?? "<nil>")")

        // Also probe the canonical track when provided (covers often shadow the original).
        if let overrideID = query.count >= 3 ? Int(query[2]) : nil {
            songID = overrideID
        }

        var lyricComponents = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyricComponents.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
            URLQueryItem(name: "yv", value: "-1"),
        ]
        var lyricRequest = URLRequest(url: lyricComponents.url!)
        lyricRequest.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")
        lyricRequest.setValue(neteaseCookie, forHTTPHeaderField: "Cookie")
        lyricRequest.setValue("https://music.163.com", forHTTPHeaderField: "Referer")

        let (lyricData, lyricResponse) = try await URLSession.shared.data(for: lyricRequest)
        print("\n=== api/lyric: HTTP \((lyricResponse as? HTTPURLResponse)?.statusCode ?? -1) ===")
        guard let lyricJSON = try? JSONSerialization.jsonObject(with: lyricData) as? [String: Any] else {
            print(prettyJSON(lyricData))
            return
        }

        for key in ["lrc", "klyric", "yrc", "tlyric"] {
            guard let section = lyricJSON[key] as? [String: Any], let lyric = section["lyric"] as? String, !lyric.isEmpty else {
                print("\(key): <empty>")
                continue
            }
            let lines = lyric.split(separator: "\n")
            print("\(key): \(lines.count) lines")
            for line in lines.prefix(3) {
                print("  \(line.prefix(160))")
            }
        }
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

/// Probes the keyless Google Translate web endpoint used by open-source clients.
private func probeTranslate(_ args: [String]) async {
    let text = args.count >= 2 ? args[1] : "Hello, world!\nThis is a second line."
    let target = args.count >= 3 ? args[2] : "de"

    var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
    components.queryItems = [
        URLQueryItem(name: "client", value: "gtx"),
        URLQueryItem(name: "sl", value: "auto"),
        URLQueryItem(name: "tl", value: target),
        URLQueryItem(name: "dt", value: "t"),
        URLQueryItem(name: "q", value: text),
    ]

    var request = URLRequest(url: components.url!)
    request.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        print("HTTP \(http.statusCode)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = json.first as? [[Any]]
        else {
            print(prettyJSON(data))
            return
        }

        let translated = segments.compactMap { $0.first as? String }.joined()
        print("detected source lang: \(json.count > 2 ? "\(json[2])" : "<nil>")")
        print("segments: \(segments.count), translated line count: \(translated.split(separator: "\n", omittingEmptySubsequences: false).count)")
        print("joined translation:")
        print(translated)
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

/// Probes NetEase's eapi lyric endpoint (yrc word-level timing).
/// eapi = AES-128-ECB over "<url>-36cd479b6b5-<json>-36cd479b6b5-<md5>" with the
/// public app key, as implemented by NeteaseCloudMusicApi.
private func probeNetEaseEapi(_ args: [String]) async {
    let songID = args.count >= 2 ? args[1] : "186016"
    let path = "/api/song/lyric/v1"

    // eapi embeds the client header object inside the encrypted payload.
    let headerObject: [String: String] = [
        "osver": "17.4.1",
        "deviceId": "iOS17.4.1",
        "os": "ios",
        "appver": "9.0.90",
        "versioncode": "140",
        "mobilename": "iPhone",
        "buildver": String(Int(Date().timeIntervalSince1970)),
        "resolution": "1170x2532",
        "__csrf": "",
        "channel": "",
        "requestId": "\(Int(Date().timeIntervalSince1970 * 1000))_0001",
    ]
    var body: [String: Any] = [
        "id": songID,
        "cp": false,
        "tv": 0,
        "lv": 0,
        "rv": 0,
        "kv": 0,
        "yv": 0,
        "ytv": 0,
        "yrv": 0,
        "csrf_token": "",
    ]
    body["header"] = headerObject

    func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        var bytes = [UInt8](data)
        CC_MD5(&bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // AES-128-ECB with PKCS7, output uppercase hex.
    func aesEapiEncryptHex(_ data: Data) -> String? {
        let key = Array("e82ckenh8dichen8".utf8)
        let dataBytes = [UInt8](data)
        let paddedLength = ((dataBytes.count / 16) + 1) * 16
        var padded = dataBytes
        let pad = paddedLength - dataBytes.count
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        var out = [UInt8](repeating: 0, count: paddedLength)
        var outLength = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), UInt32(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, kCCKeySizeAES128, nil,
            &padded, padded.count,
            &out, out.count, &outLength
        )
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLength).map { String(format: "%02X", $0) }.joined()
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
    let jsonText = String(decoding: jsonData, as: UTF8.self)
    let message = "nobody\(path)use\(jsonText)md5forencrypt"
    let digest = md5Hex(Data(message.utf8))
    let eapiData = "\(path)-36cd479b6b5-\(jsonText)-36cd479b6b5-\(digest)"
    guard let params = aesEapiEncryptHex(Data(eapiData.utf8)) else {
        print("❌ AES encryption failed")
        return
    }
    print("params head: \(params.prefix(48))")
    print("eapiData: \(eapiData.prefix(120))")
    // Diagnostic: persist the params so curl can replay the exact request.
    let diagPath = NSTemporaryDirectory() + "kaset-eapi-params.txt"
    try? "params=\(params)".write(toFile: diagPath, atomically: true, encoding: .utf8)
    print("params saved to: \(diagPath)")

    guard let url = URL(string: "https://interface3.music.163.com/eapi/song/lyric/v1") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue(
        "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)",
        forHTTPHeaderField: "User-Agent"
    )
    request.setValue(
        headerObject.map { "\($0)=\($0.1)" }.joined(separator: "; "),
        forHTTPHeaderField: "Cookie"
    )
    request.setValue(
        "application/x-www-form-urlencoded",
        forHTTPHeaderField: "Content-Type"
    )
    request.httpBody = "params=\(params)".data(using: .utf8)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        print("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1), body \(data.count) bytes")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print(String(decoding: data.prefix(500), as: UTF8.self))
            return
        }
        print("keys: \(json.keys.sorted())")
        if let code = json["code"] as? Int, code != 200 {
            print("code: \(code)")
        }
        for key in ["lrc", "klyric", "yrc", "tlyric", "rlyric", "romalrc"] {
            guard let section = json[key] as? [String: Any],
                  let lyric = section["lyric"] as? String,
                  !lyric.isEmpty
            else {
                print("\(key): <empty>")
                continue
            }
            let lines = lyric.split(separator: "\n")
            print("\(key): \(lines.count) lines")
            // For yrc/lrc show a mid-song line too — header lines are metadata.
            let offsets = lines.count >= 12 ? [0, 8, 9] : Array(lines.indices.prefix(3))
            for index in offsets {
                print("  [\(index)] \(lines[index].prefix(260))")
            }
        }
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

/// Probes KuGou (the line-level provider OuterTune/Metrolist ship).
private func probeKuGou(_ args: [String]) async {
    let title = args.count >= 2 ? args[1] : "晴天"
    let artist = args.count >= 3 ? args[2] : "周杰伦"

    var searchComponents = URLComponents(string: "https://mobileservice.kugou.com/api/v3/search/song")!
    searchComponents.queryItems = [
        URLQueryItem(name: "version", value: "9108"),
        URLQueryItem(name: "plat", value: "0"),
        URLQueryItem(name: "pagesize", value: "5"),
        URLQueryItem(name: "showtype", value: "0"),
        URLQueryItem(name: "keyword", value: "\(title) - \(artist)"),
    ]
    var searchRequest = URLRequest(url: searchComponents.url!)
    searchRequest.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")

    do {
        let (data, response) = try await URLSession.shared.data(for: searchRequest)
        guard let http = response as? HTTPURLResponse else { return }
        print("search HTTP \(http.statusCode)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataSection = json["data"] as? [String: Any],
              let infos = dataSection["info"] as? [[String: Any]],
              let first = infos.first,
              let hash = first["hash"] as? String
        else {
            print(prettyJSON(data))
            return
        }
        print("first: \(first["songname"] ?? "<nil>"), hash=\(hash), duration=\(first["duration"] ?? "<nil>")")

        var lyricSearchComponents = URLComponents(string: "https://lyrics.kugou.com/search")!
        lyricSearchComponents.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "hash", value: hash),
        ]
        var lyricSearchRequest = URLRequest(url: lyricSearchComponents.url!)
        lyricSearchRequest.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")

        let (lyricSearchData, lyricSearchResponse) = try await URLSession.shared.data(for: lyricSearchRequest)
        print("\nlyrics search HTTP \((lyricSearchResponse as? HTTPURLResponse)?.statusCode ?? -1)")
        guard let lyricJSON = try? JSONSerialization.jsonObject(with: lyricSearchData) as? [String: Any],
              let candidates = lyricJSON["candidates"] as? [[String: Any]]
        else {
            print(prettyJSON(lyricSearchData))
            return
        }
        if candidates.isEmpty {
            print("candidates empty; keys: \(lyricJSON.keys.sorted())")
            return
        }
        let candidate = candidates.first!
        guard let candidateID = candidate["id"] as? String,
              let accessKey = candidate["accesskey"] as? String
        else {
            print(prettyJSON(lyricSearchData))
            return
        }
        print("candidate: id=\(candidateID), duration=\(candidate["duration"] ?? "<nil>")")

        var downloadComponents = URLComponents(string: "https://lyrics.kugou.com/download")!
        downloadComponents.queryItems = [
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "id", value: String(candidateID)),
            URLQueryItem(name: "accesskey", value: accessKey),
        ]
        var downloadRequest = URLRequest(url: downloadComponents.url!)
        downloadRequest.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")

        let (downloadData, downloadResponse) = try await URLSession.shared.data(for: downloadRequest)
        print("\nlyrics download HTTP \((downloadResponse as? HTTPURLResponse)?.statusCode ?? -1)")
        guard let downloadJSON = try? JSONSerialization.jsonObject(with: downloadData) as? [String: Any],
              let downloadBody = downloadJSON["content"] as? [String: Any],
              let content = downloadBody["content"] as? String,
              let decoded = Data(base64Encoded: content),
              let lrc = String(data: decoded, encoding: .utf8)
        else {
            print(prettyJSON(downloadData))
            return
        }
        print("status: \(downloadBody["status"] ?? "<nil>"), fmt: \(downloadBody["fmt"] ?? "<nil>")")
        print("lrc lines: \(lrc.split(separator: "\n").count)")
        for line in lrc.split(separator: "\n").prefix(4) {
            print("  \(line.prefix(120))")
        }
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

func runLyricsProbe(_ args: [String]) async {
    guard let mode = args.first else {
        print("❌ Usage: lyrics-probe <musixmatch-token|musixmatch|netease|translate> [args]")
        return
    }

    switch mode {
    case "musixmatch-token":
        _ = await fetchMusixmatchToken()
    case "musixmatch":
        await probeMusixmatch(query: args)
    case "musixmatch-web":
        // Signed web flow: track.richsync.get with track_id from track.search
        let track = args.count >= 2 ? args[1] : "Shape of You"
        let artist = args.count >= 3 ? args[2] : "Ed Sheeran"
        let q = "app_id=web-desktop-app-v1.0&format=json&q_track=\(track)&q_artist=\(artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        await musixmatchWebRequest(method: "track.search", query: q.replacingOccurrences(of: "%20", with: "+"))
    case "netease":
        await probeNetEase(query: args)
    case "netease-eapi":
        await probeNetEaseEapi(args)
    case "kugou":
        await probeKuGou(args)
    case "translate":
        await probeTranslate(args)
    default:
        print("❌ Unknown lyrics-probe mode: \(mode)")
    }
}
