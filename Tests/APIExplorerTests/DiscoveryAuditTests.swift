import Foundation
import Testing
@testable import APIExplorer

@Suite("Read-only API discovery")
struct DiscoveryAuditTests {
    @Test("The mobile profile keeps its version and device identity consistent")
    func mobileRequestProfile() {
        let profile = MusicMobileRequestProfile(client: .ios, version: "9.07.1")
        let context = profile.clientContext(language: "tr")
        #expect(context["clientName"] as? String == "IOS_MUSIC")
        #expect(context["clientVersion"] as? String == "9.07.1")
        #expect(context["platform"] as? String == "MOBILE")
        #expect(context["hl"] as? String == "tr")
        #expect(context["browserName"] == nil)
        #expect(context["browserVersion"] == nil)
        #expect(profile.userAgent.contains("/9.07.1 "))
        #expect(MusicMobileRequestProfile(client: .ios).version == MusicMobileRequestProfile.Client.ios.defaultVersion)
    }

    @Test("Android identity and mobile authentication headers remain consistent")
    func androidProfileAndHeaders() throws {
        let profile = MusicMobileRequestProfile(client: .android, version: "7.21.50")
        let context = profile.clientContext(language: "en")
        #expect(context["clientName"] as? String == "ANDROID_MUSIC")
        #expect(context["osName"] as? String == "Android")
        #expect(context["androidSdkVersion"] as? Int == 36)
        #expect(context["platform"] as? String == "MOBILE")
        #expect(context["deviceModel"] == nil)

        var request = try URLRequest(url: #require(URL(string: "https://music.youtube.com/youtubei/v1/browse")))
        request.setValue("test-cookie", forHTTPHeaderField: "Cookie")
        request.setValue("SAPISIDHASH mock-proof", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("test-account", forHTTPHeaderField: "X-Goog-PageId")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        profile.applyHeaders(to: &request, cookieOnly: false, accessToken: nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "SAPISIDHASH mock-proof")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("/7.21.50 ") == true)
        #expect(request.value(forHTTPHeaderField: "X-Youtube-Client-Name") == "21")
        #expect(request.value(forHTTPHeaderField: "X-Youtube-Client-Version") == "7.21.50")

        profile.applyHeaders(to: &request, cookieOnly: true, accessToken: nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "test-cookie")

        profile.applyHeaders(to: &request, cookieOnly: false, accessToken: "mock-access-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mock-access-token")
        for field in ["Cookie", "X-Goog-AuthUser", "X-Goog-PageId", "X-Origin", "Origin", "Referer"] {
            #expect(request.value(forHTTPHeaderField: field) == nil)
        }
    }

    @Test("Mobile OAuth requires a private regular file and cannot inject headers")
    func mobileTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("access-token")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("mock-access-token\n".utf8), attributes: [.posixPermissions: 0o600]))
        #expect(try loadMobileAccessToken(from: file.path) == "mock-access-token")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try loadMobileAccessToken(from: file.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try loadMobileAccessToken(from: link.path) }
        #expect(throws: (any Error).self) { try loadMobileAccessToken(from: "-") }

        for invalid in ["", "Bearer mock-token", "mock-token\r\nCookie: test-cookie", String(repeating: "x", count: 8193)] {
            try Data(invalid.utf8).write(to: file)
            #expect(throws: (any Error).self) { try loadMobileAccessToken(from: file.path) }
        }
    }

    @Test("Mobile OAuth cannot be sent through a web profile")
    func mobileTokenDestination() async {
        await #expect(throws: DiscoveryError.self) {
            try await makeWireRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"], mobileAccessToken: "mock-token")
        }
    }

    @Test("Service metadata distinguishes an authenticated mobile response from guest content", arguments: ["0", "1"])
    func serviceLoginFlags(flag: String) throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let response: [String: Any] = ["responseContext": ["serviceTrackingParams": [
            ["service": "GFEEDBACK", "params": [["key": "logged_in", "value": flag], ["key": "account", "value": "private-account"]]],
            ["service": "CSI", "params": [["key": "yt_li", "value": flag]]],
        ]]]
        let audit = DiscoveryAudit(response: response, request: request)
        #expect(audit.serverLoggedOut == (flag == "0"))
        #expect(!audit.rendered(verbose: true).contains("private-account"))
    }

    @Test("Conflicting or unfamiliar login flags do not establish authentication")
    func inconclusiveServiceLoginFlags() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        for flags in [["0", "1"], ["private-value"], ["1", "false"], ["0", "private-value"], []] {
            let params = flags.map { ["key": "logged_in", "value": $0] }
            let audit = DiscoveryAudit(response: ["responseContext": ["serviceTrackingParams": [["params": params]]]], request: request)
            #expect(audit.serverLoggedOut == nil)
        }
        let invalidFlags: [Any] = [1, true, NSNull()]
        for invalid in invalidFlags {
            let params: [[String: Any]] = [["key": "logged_in", "value": "1"], ["key": "yt_li", "value": invalid]]
            let audit = DiscoveryAudit(response: ["responseContext": ["serviceTrackingParams": [["params": params]]]], request: request)
            #expect(audit.serverLoggedOut == nil)
        }
    }

    @Test("Error categories and web shelf summaries hide arbitrary response values")
    func errorAndShelfRedaction() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let response: [String: Any] = [
            "error": ["status": "INVALID_ARGUMENT", "message": "Request contains an invalid argument."],
            "contents": ["musicCarouselShelfRenderer": [
                "shelfId": "private-shelf-id",
                "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "Listen again"]]]]],
                "contents": [["title": "Private item"]],
            ]],
        ]
        let audit = DiscoveryAudit(response: response, request: request)
        #expect(audit.apiErrorSummary == "INVALID_ARGUMENT; invalid argument")
        #expect(audit.homeShelves == ["label=Listen again; items=1"])
        #expect(audit.speedDialItemCount == 0)
        let report = audit.rendered(verbose: true)
        #expect(!report.contains("private-shelf-id"))
        #expect(!report.contains("Private item"))
        let unknown = DiscoveryAudit(response: ["error": ["status": "private-status", "message": "mock-token"]], request: request)
        #expect(unknown.apiErrorSummary == "unrecognized status; message hidden")
    }

    @Test("Mobile Speed dial models expose counts and read commands without private values")
    func mobileSpeedDial() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let model: [String: Any] = ["musicSpeedDialShelfModel": ["data": ["items": [
            [
                "title": "Private song title",
                "startPlaybackCommand": ["serialCommand": ["commands": [
                    ["innertubeCommand": ["watchEndpoint": [
                        "videoId": "test-video", "playlistId": "test-radio", "params": "mock-play",
                    ]]],
                    ["innertubeCommand": ["feedbackEndpoint": ["feedbackToken": "mock-feedback"]]],
                ]]],
            ],
            [
                "title": "Private playlist title",
                "navigationCommand": ["innertubeCommand": ["browseEndpoint": [
                    "browseId": "VLtest-playlist", "params": "mock-browse",
                ]]],
            ],
            ["isShortcut": true],
        ]]]]
        let audit = DiscoveryAudit(response: ["contents": ["itemSectionRenderer": ["contents": [
            ["elementRenderer": ["newElement": ["type": ["componentType": ["model": model]]]]],
        ]]]], request: request)

        #expect(audit.renderers["musicSpeedDialShelfModel"] == 1)
        #expect(audit.speedDialItemCount == 3)
        #expect(audit.speedDialShortcutCount == 1)
        #expect(audit.navigation.count == 2)
        let playRead = try #require(audit.navigation.first { $0.request.endpoint == "next" })
        #expect(playRead.request.body["params"] as? String == "mock-play")
        #expect(playRead.request.body["playlistId"] as? String == "test-radio")
        #expect(audit.observedCommands["feedbackEndpoint"] == 1)
        let report = audit.rendered(verbose: true)
        #expect(report.contains("Speed dial models: 1; items: 3; shortcuts: 1"))
        for privateValue in ["Private", "test-video", "test-radio", "test-playlist", "mock-"] {
            #expect(!report.contains(privateValue))
        }
    }

    @Test("A Speed dial label or an empty model does not imply populated Speed dial items")
    func speedDialPresence() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let audit = DiscoveryAudit(response: ["contents": [
            "musicSpeedDialShelfModel": ["data": [:]],
            "musicGridItemCarouselModel": ["data": [
                "title": "Speed dial", "items": [["title": "Private item"]],
            ]],
        ]], request: request)
        #expect(audit.renderers["musicSpeedDialShelfModel"] == 1)
        #expect(audit.renderers["musicGridItemCarouselModel"] == 1)
        #expect(audit.speedDialItemCount == 0)
        #expect(audit.speedDialShortcutCount == 0)
    }

    @Test("Seeds reject mutations even when sent through browse", arguments: [
        "feedback", "playlist/create", "browse/edit_playlist", "subscription/subscribe", "get_answer",
    ])
    func rejectsMutationEndpoints(endpoint: String) {
        #expect(throws: DiscoveryError.self) {
            try DiscoveryRequest(endpoint: endpoint, body: ["videoId": "test-video"])
        }
    }

    @Test("Browse forms cannot update recommendation preferences")
    func rejectsBrowseFormData() {
        #expect(throws: DiscoveryError.self) {
            try DiscoveryRequest(endpoint: "browse", body: [
                "browseId": "FEmusic_home", "formData": ["selectedValues": ["mock-token"]],
            ])
        }
        #expect(throws: DiscoveryError.self) {
            try DiscoveryRequest(endpoint: "browse", body: ["browseId": ["formData": "mock-token"]])
        }
        #expect(throws: DiscoveryError.self) {
            try DiscoveryRequest(endpoint: "next", body: ["params": "mock-token"])
        }
    }

    @Test("Only the chart country form is accepted")
    func chartFormBoundary() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: [
            "browseId": "FEmusic_charts", "formData": ["selectedValues": ["JP"]],
        ])
        #expect(request.endpoint == "browse")
        for form: [String: Any] in [
            ["selectedValues": ["mock-token"]],
            ["selectedValues": ["JP", "US"]],
            ["selectedValues": ["JP"], "impressionValues": ["mock-token"]],
            ["selectedValues": []],
        ] {
            #expect(throws: DiscoveryError.self) {
                try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_charts", "formData": form])
            }
        }
    }

    @Test("Chart choices are extracted only from chart responses")
    func chartChoices() throws {
        let response: [String: Any] = ["frameworkUpdates": ["entityBatchUpdate": ["mutations": [
            ["payload": ["musicFormBooleanChoice": ["opaqueToken": "JP", "selected": true]]],
            ["payload": ["musicFormBooleanChoice": ["opaqueToken": "US"]]],
            ["payload": ["musicFormBooleanChoice": ["opaqueToken": "JP"]]],
            ["payload": ["musicFormBooleanChoice": ["opaqueToken": "mock-token"]]],
        ]]]]
        let chart = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_charts"])
        let home = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let audit = DiscoveryAudit(response: response, request: chart)
        #expect(audit.chartCountryCount == 2)
        #expect(audit.navigation.count == 2)
        #expect(audit.selectedChartCountries == ["JP"])
        let form = try #require(audit.navigation.first?.request.body["formData"] as? [String: Any])
        #expect(form["selectedValues"] as? [String] == ["JP"])
        #expect(DiscoveryAudit(response: response, request: home).navigation.isEmpty)
        #expect(!audit.rendered(verbose: true).contains("mock-token"))
    }

    @Test("Transcript retrieval is extracted without executing sibling commands")
    func transcriptInServiceBatch() throws {
        let request = try DiscoveryRequest(endpoint: "next", body: ["videoId": "test-video"])
        let audit = DiscoveryAudit(response: ["serviceEndpoint": ["commandExecutorCommand": ["commands": [
            ["getTranscriptEndpoint": ["params": "mock-transcript"]],
            ["feedbackEndpoint": ["feedbackToken": "mock-feedback"]],
            ["browseEndpoint": ["browseId": "FEmusic_home"]],
        ]]]], request: request)
        #expect(audit.navigation.count == 1)
        #expect(audit.navigation.first?.request.endpoint == "get_transcript")
        #expect(audit.navigation.first?.request.body["params"] as? String == "mock-transcript")
        #expect(!audit.rendered(verbose: true).contains("mock-"))
    }

    @Test("Credits, related content, chips, and search preserve issued parameters without printing them")
    func harvestsNavigation() throws {
        let request = try DiscoveryRequest(endpoint: "next", body: ["videoId": "test-video"])
        let response: [String: Any] = [
            "contents": [
                "musicQueueRenderer": [
                    "items": [
                        ["menuNavigationItemRenderer": [
                            "text": ["runs": [["text": "Song credits"]]],
                            "navigationEndpoint": [
                                "clickTrackingParams": "mock-tracking",
                                "browseEndpoint": ["browseId": "MPTC-private-id", "params": "mock-credits"],
                            ],
                        ]],
                        ["tabRenderer": [
                            "title": "Related",
                            "endpoint": ["browseEndpoint": ["browseId": "MPTR-private-id"]],
                        ]],
                        ["chipCloudChipRenderer": [
                            "text": ["simpleText": "Focus"],
                            "navigationEndpoint": ["browseSectionListReloadEndpoint": [
                                "browseId": "FEmusic_home", "params": "mock-focus",
                            ]],
                        ]],
                        ["chipCloudChipRenderer": [
                            "text": ["runs": [["text": "Albums"]]],
                            "navigationEndpoint": ["searchEndpoint": ["query": "private-query", "params": "mock-filter"]],
                        ]],
                    ],
                ],
            ],
        ]
        let audit = DiscoveryAudit(response: response, request: request)
        #expect(audit.navigation.count == 4)
        #expect(audit.navigation[0].label == "Song credits")
        #expect(audit.navigation[0].request.body["params"] as? String == "mock-credits")
        #expect(audit.navigation[1].request.body["browseId"] as? String == "MPTR-private-id")
        #expect(audit.navigation[2].request.body["params"] as? String == "mock-focus")
        #expect(audit.navigation[3].request.endpoint == "search")
        #expect(audit.navigation[3].request.body["query"] as? String == "private-query")
        #expect(audit.rendered().contains("MPTC…"))
        #expect(!audit.rendered(verbose: true).contains("private-id"))
        #expect(!audit.rendered(verbose: true).contains("mock-"))
        #expect(!audit.rendered(verbose: true).contains("private-query"))
    }

    @Test("Continuation retains next's queue context and uses next routing", arguments: [
        "nextContinuationData", "nextRadioContinuationData", "reloadContinuationData",
    ])
    func continuationContext(key: String) throws {
        let request = try DiscoveryRequest(endpoint: "next", body: [
            "videoId": "test-video", "playlistId": "test-playlist", "isAudioOnly": true,
        ])
        let audit = DiscoveryAudit(response: [
            "continuations": [[key: ["continuation": "mock-continuation"]]],
        ], request: request)
        let continuation = try #require(audit.navigation.first?.request)
        #expect(continuation.endpoint == "next")
        #expect(continuation.body["videoId"] as? String == "test-video")
        #expect(continuation.body["playlistId"] as? String == "test-playlist")
        #expect(continuation.body["continuation"] as? String == "mock-continuation")
        #expect(continuation.body["isAudioOnly"] as? Bool == true)
    }

    @Test("Queue filter navigation retains audio and persistent-panel configuration")
    func queueFilterContext() throws {
        let request = try DiscoveryRequest(endpoint: "next", body: [
            "videoId": "test-video", "playlistId": "test-playlist", "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
        ])
        let audit = DiscoveryAudit(response: ["chipCloudChipRenderer": [
            "text": ["simpleText": "Popular"], "isSelected": true,
            "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "test-radio", "params": "mock-filter"]],
        ]], request: request)
        let filter = try #require(audit.navigation.first?.request)
        #expect(filter.endpoint == "next")
        #expect(filter.body["isAudioOnly"] as? Bool == true)
        #expect(filter.body["enablePersistentPlaylistPanel"] as? Bool == true)
        #expect(filter.body["videoId"] == nil)
        #expect(filter.body["params"] as? String == "mock-filter")
        #expect(audit.selectedChips == ["Popular"])
    }

    @Test("Deselect actions do not masquerade as a filter selection")
    func ignoresDeselectAction() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let audit = DiscoveryAudit(response: ["chipCloudChipRenderer": [
            "text": ["simpleText": "Focus"],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "FEmusic_home", "params": "mock-focus"]],
            "onDeselectedCommand": ["browseEndpoint": ["browseId": "FEmusic_home", "params": "mock-reset"]],
        ]], request: request)
        #expect(audit.navigation.count == 1)
        #expect(audit.navigation.first?.request.body["params"] as? String == "mock-focus")
    }

    @Test("Credit headings alone are distinguished from populated sections")
    func populatedCredits() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "MPTC-test"])
        let audit = DiscoveryAudit(response: ["contents": [
            ["dismissableDialogContentSectionRenderer": [
                "title": ["simpleText": "Performed by"], "subtitle": ["runs": [["text": "Test performer"]]],
            ]],
            ["dismissableDialogContentSectionRenderer": ["title": ["simpleText": "Written by"]]],
        ]], request: request)
        #expect(audit.creditSectionCount == 2)
        #expect(audit.populatedCreditSectionCount == 1)
        #expect(!audit.rendered(verbose: true).contains("Test performer"))
    }

    @Test("Service commands and form submissions are inspected but never replayable")
    func excludesSideEffects() throws {
        let endpoint: [String: Any] = ["browseEndpoint": ["browseId": "FEmusic_home"]]
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_radio_builder"])
        let audit = DiscoveryAudit(response: [
            "serviceEndpoint": endpoint,
            "commandExecutorCommand": ["commands": [endpoint]],
            "submitEndpoint": endpoint,
            "formData": endpoint,
            "navigationEndpoint": ["browseEndpoint": [
                "browseId": "FEmusic_home", "formData": ["selectedValues": ["mock-token"]],
            ]],
        ], request: request)
        #expect(audit.navigation.isEmpty)
        #expect(audit.observedCommands["browseEndpoint"] == 5)
        #expect(!audit.rendered(verbose: true).contains("mock-token"))
    }

    @Test("Only known UI labels and schema names appear in a report")
    func redactsValuesAndDynamicKeys() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "UC-private-account"])
        let audit = DiscoveryAudit(response: [
            "responseContext": ["visitorData": "mock-visitor", "mainAppWebResponseContext": ["loggedOut": false]],
            "error": ["message": "private-error", "code": 400],
            "contents": ["musicShelfRenderer": [
                "title": ["runs": [["text": "Private playlist title"]]],
                "accountId": "private-account",
                "mock-key-123": "mock-token",
                "accessToken": "mock-access",
                "text": "\u{001B}[31mPrivate text",
                "browseEndpoint": ["browseId": "UC-private-account"],
            ]],
        ], request: request)
        let report = audit.rendered(verbose: true)
        #expect(audit.serverLoggedOut == false)
        #expect(audit.hasAPIError)
        #expect(report.contains("musicShelfRenderer"))
        #expect(report.contains("<key>"))
        #expect(report.contains("UC…"))
        for value in ["private-account", "Private", "private-error", "mock-", "\u{001B}"] {
            #expect(!report.contains(value))
        }
        #expect(!request.summary.contains("private-account"))
    }

    @Test("An HTTP 200 responseContext-only payload does not imply feature content")
    func emptyResponse() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_listening_review"])
        let audit = DiscoveryAudit(response: ["responseContext": [:], "trackingParams": "mock-tracking"], request: request)
        #expect(!audit.hasContent)
        #expect(audit.serverLoggedOut == nil)
        #expect(audit.navigation.isEmpty)
        #expect(audit.rendered().contains("no content envelope"))
    }

    @Test("Duplicate destinations keep distinct params and deterministic order")
    func deduplication() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        let audit = DiscoveryAudit(response: ["contents": [
            ["browseEndpoint": ["browseId": "FEmusic_home", "params": "mock-first"]],
            ["browseEndpoint": ["browseId": "FEmusic_home", "params": "mock-first"]],
            ["browseEndpoint": ["browseId": "FEmusic_home", "params": "mock-second"]],
        ]], request: request)
        #expect(audit.navigation.count == 2)
        #expect(audit.navigation[0].request.body["params"] as? String == "mock-first")
        #expect(audit.navigation[1].request.body["params"] as? String == "mock-second")
    }

    @Test("Deep payloads stop at the audit limit")
    func traversalBound() throws {
        let request = try DiscoveryRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        var response: [String: Any] = ["browseEndpoint": ["browseId": "FEmusic_charts"]]
        for _ in 0 ..< 90 {
            response = ["nested": response]
        }
        let audit = DiscoveryAudit(response: response, request: request)
        #expect(audit.truncated)
        #expect(audit.navigation.isEmpty)
    }
}
