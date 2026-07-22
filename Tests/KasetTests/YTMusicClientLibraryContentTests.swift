// swiftlint:disable file_length

import Foundation
import Testing
@testable import Kaset

// MARK: - YTMusicClientLibraryRequestTests

@Suite(.serialized, .tags(.api), .timeLimit(.minutes(1)))
@MainActor
struct YTMusicClientLibraryRequestTests {
    @Test("Library content fetches all saved album pages and stops on a repeated token")
    func libraryContentFetchesAllSavedAlbumPages() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()
        let recorder = LibraryRequestRecorder()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )

            let payload: [String: Any]
            let statusCode: Int
            if let continuation = body["continuation"] as? String {
                recorder.appendCursor(continuation)
                switch continuation {
                case "albums-page-2":
                    payload = Self.libraryAlbumsContinuationPayload(
                        albumID: "MPREALBUMB",
                        title: "Album B",
                        nextPage: "albums-page-3"
                    )
                    statusCode = 200
                case "albums-page-3":
                    payload = Self.libraryAlbumsContinuationPayload(
                        albumID: "MPREALBUMC",
                        title: "Album C",
                        nextPage: "albums-page-2"
                    )
                    statusCode = 200
                default:
                    payload = [:]
                    statusCode = 400
                }
            } else if let browseID = body["browseId"] as? String {
                recorder.appendBrowseID(browseID)
                switch browseID {
                case "FEmusic_liked_albums":
                    payload = Self.libraryAlbumsPagePayload(
                        albumID: "MPREALBUMA",
                        title: "Album A",
                        nextPage: "albums-page-2"
                    )
                    statusCode = 200
                case "FEmusic_library_landing",
                     "FEmusic_liked_playlists",
                     "FEmusic_library_corpus_artists",
                     Playlist.uploadedSongsBrowseID:
                    payload = [:]
                    statusCode = 200
                default:
                    payload = [:]
                    statusCode = 400
                }
            } else {
                payload = [:]
                statusCode = 400
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == [
            "MPREALBUMA",
            "MPREALBUMB",
            "MPREALBUMC",
        ])
        #expect(recorder.cursors == [
            "albums-page-2",
            "albums-page-3",
        ])
        #expect(recorder.browseIDs == [
            "FEmusic_library_landing",
            "FEmusic_liked_playlists",
            "FEmusic_liked_albums",
            "FEmusic_library_corpus_artists",
            Playlist.uploadedSongsBrowseID,
        ])
        #expect(content.albumsSource == .partial)
    }

    @Test("Complete dedicated album results exclude landing-only previews")
    func completeDedicatedAlbumsExcludeLandingPreview() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let payload: [String: Any] = switch body["browseId"] as? String {
            case "FEmusic_library_landing":
                Self.libraryAlbumsPagePayload(
                    albumID: "MPREPREVIEW",
                    title: "Preview Album",
                    nextPage: nil
                )
            case "FEmusic_liked_albums":
                Self.libraryAlbumsPagePayload(
                    albumID: "MPREDEDICATED",
                    title: "Dedicated Album",
                    nextPage: nil
                )
            default:
                [:]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == ["MPREDEDICATED"])
        #expect(content.albumsSource == .dedicated)
    }

    @Test("Library content paginates shelf-based saved album responses")
    func libraryContentPaginatesShelfBasedAlbums() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let payload: [String: Any] = if body["continuation"] as? String == "albums-page-2" {
                Self.libraryAlbumsShelfContinuationPayload(
                    albumID: "MPRESHELFB",
                    title: "Shelf Album B"
                )
            } else if body["browseId"] as? String == "FEmusic_liked_albums" {
                Self.libraryAlbumsShelfPagePayload(
                    albumID: "MPRESHELFA",
                    title: "Shelf Album A",
                    nextPage: "albums-page-2"
                )
            } else {
                [:]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == ["MPRESHELFA", "MPRESHELFB"])
        #expect(content.albumsSource == .dedicated)
    }

    @Test("Library content consumes independent album continuation chains")
    func libraryContentConsumesIndependentAlbumContinuations() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let payload: [String: Any] = switch body["continuation"] as? String {
            case "shelf-one-next":
                Self.libraryAlbumsShelfContinuationPayload(
                    albumID: "MPRESHELFONECONTINUED",
                    title: "Shelf One Continued"
                )
            case "shelf-two-next":
                Self.libraryAlbumsShelfContinuationPayload(
                    albumID: "MPRESHELFTWOCONTINUED",
                    title: "Shelf Two Continued"
                )
            default:
                if body["browseId"] as? String == "FEmusic_liked_albums" {
                    Self.libraryAlbumsMultipleShelfPagePayload()
                } else {
                    [:]
                }
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(Set(content.albums.map(\.id)) == Set([
            "MPRESHELFONE",
            "MPRESHELFTWO",
            "MPRESHELFONECONTINUED",
            "MPRESHELFTWOCONTINUED",
        ]))
        #expect(content.albumsSource == .dedicated)
    }

    @Test("Library content marks landing albums as fallback when the dedicated request fails")
    func libraryContentMarksAlbumFallbackAfterDedicatedFailure() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            let browseID = body["browseId"] as? String
            let statusCode = browseID == "FEmusic_liked_albums" ? 400 : 200
            let payload: [String: Any] = if browseID == "FEmusic_library_landing" {
                Self.libraryAlbumsPagePayload(
                    albumID: "MPREFALLBACK",
                    title: "Fallback Album",
                    nextPage: nil
                )
            } else {
                [:]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let primaryAccountScope = FavoritesManager.accountScopeID(
            ownerID: "primary-owner",
            accountID: "primary"
        )
        let client = try await Self.makeAuthenticatedClient(session: session)
        client.accountScopeProvider = { primaryAccountScope }
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == ["MPREFALLBACK"])
        #expect(content.albumsSource == .landingFallback)
        #expect(content.accountScope == primaryAccountScope)
    }

    @Test("Library content treats a recognized empty saved-albums page as authoritative")
    func libraryContentTreatsRecognizedEmptyAlbumsAsAuthoritative() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let browseID = body["browseId"] as? String
            let payload: [String: Any] = if browseID == "FEmusic_library_landing" {
                Self.libraryAlbumsPagePayload(
                    albumID: "MPREFALLBACK",
                    title: "Fallback Album",
                    nextPage: nil
                )
            } else if browseID == "FEmusic_liked_albums" {
                Self.emptyLibraryAlbumsPagePayload(nextPage: nil)
            } else {
                [:]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.isEmpty)
        #expect(content.albumsSource == .dedicated)
    }

    @Test("Library content keeps empty incomplete pagination non-authoritative")
    func libraryContentKeepsEmptyIncompletePaginationNonAuthoritative() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let payload: [String: Any]
            let statusCode: Int
            if body["continuation"] != nil {
                payload = [:]
                statusCode = 400
            } else if let browseID = body["browseId"] as? String {
                switch browseID {
                case "FEmusic_library_landing":
                    payload = Self.libraryAlbumsPagePayload(
                        albumID: "MPREFALLBACK",
                        title: "Fallback Album",
                        nextPage: nil
                    )
                case "FEmusic_liked_albums":
                    payload = Self.emptyLibraryAlbumsPagePayload(nextPage: "albums-page-2")
                default:
                    payload = [:]
                }
                statusCode = 200
            } else {
                payload = [:]
                statusCode = 400
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == ["MPREFALLBACK"])
        #expect(content.albumsSource == .partial)
    }

    @Test("Library content follows continuations from an unrecognized empty first page")
    func libraryContentFollowsContinuationFromUnrecognizedFirstPage() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()
        let recorder = LibraryRequestRecorder()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let payload: [String: Any]
            if let continuation = body["continuation"] as? String {
                recorder.appendCursor(continuation)
                payload = Self.libraryAlbumsContinuationPayload(
                    albumID: "MPREFROMCONTINUATION",
                    title: "Continuation Album",
                    nextPage: nil
                )
            } else if let browseID = body["browseId"] as? String {
                switch browseID {
                case "FEmusic_library_landing":
                    payload = Self.libraryAlbumsPagePayload(
                        albumID: "MPREFALLBACK",
                        title: "Fallback Album",
                        nextPage: nil
                    )
                case "FEmusic_liked_albums":
                    payload = Self.unrecognizedLibraryAlbumsPagePayload(nextPage: "albums-page-2")
                default:
                    payload = [:]
                }
            } else {
                payload = [:]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == ["MPREFROMCONTINUATION", "MPREFALLBACK"])
        #expect(content.albumsSource == .partial)
        #expect(recorder.cursors == ["albums-page-2"])
    }

    @Test("Library content marks failed album pagination as partial")
    func libraryContentMarksFailedAlbumPaginationAsPartial() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let payload: [String: Any]
            let statusCode: Int
            if let continuation = body["continuation"] as? String {
                switch continuation {
                case "albums-page-2":
                    payload = Self.libraryAlbumsContinuationPayload(
                        albumID: "MPREPARTIALB",
                        title: "Partial Album B",
                        nextPage: "albums-page-3"
                    )
                    statusCode = 200
                default:
                    payload = [:]
                    statusCode = 400
                }
            } else if let browseID = body["browseId"] as? String {
                switch browseID {
                case "FEmusic_library_landing":
                    payload = Self.libraryAlbumsPagePayload(
                        albumID: "MPREFALLBACK",
                        title: "Fallback Album",
                        nextPage: nil
                    )
                    statusCode = 200
                case "FEmusic_liked_albums":
                    payload = Self.libraryAlbumsPagePayload(
                        albumID: "MPREPARTIALA",
                        title: "Partial Album A",
                        nextPage: "albums-page-2"
                    )
                    statusCode = 200
                default:
                    payload = [:]
                    statusCode = 200
                }
            } else {
                payload = [:]
                statusCode = 400
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == [
            "MPREPARTIALA",
            "MPREPARTIALB",
            "MPREFALLBACK",
        ])
        #expect(content.albumsSource == .partial)
    }

    @Test("Library content propagates initial saved-albums cancellation")
    func libraryContentPropagatesInitialAlbumCancellation() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                ))
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            if body["browseId"] as? String == "FEmusic_liked_albums" {
                throw URLError(.cancelled)
            }

            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data("{}".utf8))
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        await #expect(throws: CancellationError.self) {
            try await client.getLibraryContent()
        }
    }

    @Test("Library content propagates saved-albums continuation cancellation")
    func libraryContentPropagatesAlbumContinuationCancellation() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                ))
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            if body["continuation"] != nil {
                throw URLError(.cancelled)
            }

            let payload: [String: Any] = if body["browseId"] as? String == "FEmusic_liked_albums" {
                Self.libraryAlbumsPagePayload(
                    albumID: "MPRECANCEL",
                    title: "Cancellation Album",
                    nextPage: "cancelled-page"
                )
            } else {
                [:]
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return try (response, JSONSerialization.data(withJSONObject: payload))
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        await #expect(throws: CancellationError.self) {
            try await client.getLibraryContent()
        }
    }
}

private extension YTMusicClientLibraryRequestTests {
    static func makeAuthenticatedClient(session: URLSession) async throws -> YTMusicClient {
        let webKitManager = WebKitManager.makeTestInstance()
        let cookie = try #require(HTTPCookie(properties: [
            .name: WebKitManager.fallbackAuthCookieName,
            .value: "test-cookie",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        await webKitManager.dataStore.httpCookieStore.setCookie(cookie)

        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-cookie")
        return YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session
        )
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsPagePayload(
        albumID: String,
        title: String,
        nextPage: String?
    ) -> [String: Any] {
        var gridRenderer: [String: Any] = [
            "items": [Self.libraryAlbumItem(id: albumID, title: title)],
        ]
        if let nextPage {
            gridRenderer["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["gridRenderer": gridRenderer]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsMultipleShelfPagePayload() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [
                                                    self.libraryResponsiveAlbumItem(
                                                        id: "MPRESHELFONE",
                                                        title: "Shelf One"
                                                    ),
                                                ],
                                                "continuations": [[
                                                    "nextContinuationData": [
                                                        "continuation": "shelf-one-next",
                                                    ],
                                                ]],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [
                                                    self.libraryResponsiveAlbumItem(
                                                        id: "MPRESHELFTWO",
                                                        title: "Shelf Two"
                                                    ),
                                                ],
                                                "continuations": [[
                                                    "nextContinuationData": [
                                                        "continuation": "shelf-two-next",
                                                    ],
                                                ]],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsShelfPagePayload(
        albumID: String,
        title: String,
        nextPage: String?
    ) -> [String: Any] {
        var shelfRenderer: [String: Any] = [
            "contents": [Self.libraryResponsiveAlbumItem(id: albumID, title: title)],
        ]
        if let nextPage {
            shelfRenderer["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["musicShelfRenderer": shelfRenderer]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsShelfContinuationPayload(
        albumID: String,
        title: String
    ) -> [String: Any] {
        [
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": [self.libraryResponsiveAlbumItem(id: albumID, title: title)],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func emptyLibraryAlbumsPagePayload(nextPage: String?) -> [String: Any] {
        var gridRenderer: [String: Any] = [
            "items": [],
        ]
        if let nextPage {
            gridRenderer["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["gridRenderer": gridRenderer]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
            "responseContext": [
                "serviceTrackingParams": [[
                    "params": [
                        [
                            "key": "logged_in",
                            "value": "1",
                        ],
                        [
                            "key": "browse_id",
                            "value": "FEmusic_liked_albums",
                        ],
                    ],
                ]],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func unrecognizedLibraryAlbumsPagePayload(nextPage: String) -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "gridRenderer": [
                                            "items": [[
                                                "musicTwoRowItemRenderer": [
                                                    "title": ["runs": [["text": "Unsupported Promo"]]],
                                                ],
                                            ]],
                                            "continuations": [[
                                                "nextContinuationData": ["continuation": nextPage],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsContinuationPayload(
        albumID: String,
        title: String,
        nextPage: String?
    ) -> [String: Any] {
        var gridContinuation: [String: Any] = [
            "items": [Self.libraryAlbumItem(id: albumID, title: title)],
        ]
        if let nextPage {
            gridContinuation["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "continuationContents": [
                "gridContinuation": gridContinuation,
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryResponsiveAlbumItem(id: String, title: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": id,
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                            ],
                        ],
                    ],
                ],
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": title]]],
                        ],
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    ["text": "Album"],
                                    ["text": " • "],
                                    ["text": "Test Artist"],
                                    ["text": " • "],
                                    ["text": "2026"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumItem(id: String, title: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "subtitle": [
                    "runs": [
                        ["text": "Album"],
                        ["text": " • "],
                        ["text": "Test Artist"],
                        ["text": " • "],
                        ["text": "2026"],
                    ],
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": id,
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }
}

// MARK: - LibraryRequestTestSupport

private enum LibraryRequestTestSupport {
    /// URLSession may bridge `httpBody` to a stream before URLProtocol observes the request.
    static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            throw YTMusicError.parseError(message: "Request body was missing")
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? YTMusicError.parseError(message: "Request body could not be read")
            }
            if count == 0 {
                return data
            }
            data.append(buffer, count: count)
        }
    }
}

// MARK: - LibraryRequestRecorder

private final class LibraryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBrowseIDs: [String] = []
    private var storedCursors: [String] = []

    var browseIDs: [String] {
        self.lock.withLock { self.storedBrowseIDs }
    }

    var cursors: [String] {
        self.lock.withLock { self.storedCursors }
    }

    func appendBrowseID(_ browseID: String) {
        self.lock.withLock {
            self.storedBrowseIDs.append(browseID)
        }
    }

    func appendCursor(_ cursor: String) {
        self.lock.withLock {
            self.storedCursors.append(cursor)
        }
    }
}
