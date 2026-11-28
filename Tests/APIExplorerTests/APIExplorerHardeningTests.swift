import Foundation
import Testing
@testable import APIExplorer

@Suite("API Explorer hardening")
struct APIExplorerHardeningTests {
    @Test("Cookie filtering uses DNS label boundaries for dotted and bare domains")
    func cookieDomainBoundaries() throws {
        func makeCookie(name: String, domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: name,
                .value: "test-cookie",
            ]))
        }

        let cookies = try [
            makeCookie(name: "exact", domain: "music.youtube.com"),
            makeCookie(name: "dotted-exact", domain: ".music.youtube.com"),
            makeCookie(name: "parent-bare", domain: "youtube.com"),
            makeCookie(name: "parent-dotted", domain: ".youtube.com"),
            makeCookie(name: "false-suffix-dotted", domain: ".tube.com"),
            makeCookie(name: "false-suffix-bare", domain: "tube.com"),
            makeCookie(name: "evil-prefix", domain: ".notyoutube.com"),
            makeCookie(name: "other-subdomain", domain: ".www.youtube.com"),
        ]

        let matched = filterCookiesForAPIHost(cookies, host: "music.youtube.com")
        let names = Set(matched.map(\.name))
        #expect(names == ["exact", "dotted-exact", "parent-bare", "parent-dotted"])
    }

    @Test("Saved-response diagnostics omit raw server values including error text")
    func savedResponseDiagnosticsRedaction() {
        let sentinel = "SENSITIVE_SENTINEL_VALUE_98765"
        let errorPayload: [String: Any] = [
            "error": [
                "code": 400,
                "message": "Server rejected \(sentinel)",
                "status": "INVALID_ARGUMENT",
            ],
        ]
        let errorSummary = summarizeSavedResponse(errorPayload)
        #expect(errorSummary.contains("Top-level keys"))
        #expect(errorSummary.contains("Error object keys"))
        #expect(!errorSummary.contains(sentinel))

        let contentPayload: [String: Any] = [
            "contents": [
                "musicPlaylistShelfRenderer": [
                    "contents": [
                        [
                            "musicResponsiveListItemRenderer": [
                                "title": ["runs": [["text": sentinel]]],
                                "menu": [
                                    "menuRenderer": [
                                        "items": [
                                            [
                                                "menuServiceItemRenderer": [
                                                    "icon": ["iconType": "LIBRARY_\(sentinel)"],
                                                    "serviceEndpoint": [
                                                        "feedbackEndpoint": ["feedbackToken": "mock-token-\(sentinel)"],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "header": [
                "musicResponsiveHeaderRenderer": [
                    "title": ["runs": [["text": sentinel]]],
                ],
            ],
        ]
        let contentSummary = summarizeSavedResponse(contentPayload)
        #expect(contentSummary.contains("Top-level keys"))
        #expect(contentSummary.contains("musicPlaylistShelfRenderer"))
        #expect(contentSummary.contains("LIBRARY_OTHER"))
        #expect(!contentSummary.contains(sentinel))
    }

    @Test("Account discovery continues past transient and unknown responses and stops on unavailable after success")
    func accountDiscoveryTransientAndUnknownErrors() async throws {
        let validAccountJSON = try JSONSerialization.data(withJSONObject: [
            "actions": [[
                "openPopupAction": [
                    "popup": [
                        "multiPageMenuRenderer": [
                            "header": [
                                "activeAccountHeaderRenderer": [
                                    "accountName": ["runs": [["text": "Primary"]]],
                                    "channelHandle": ["runs": [["text": "@primary"]]],
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ])
        let malformedJSON = Data("{}".utf8)
        let missingNameJSON = try JSONSerialization.data(withJSONObject: [
            "actions": [[
                "openPopupAction": [
                    "popup": [
                        "multiPageMenuRenderer": [
                            "header": [
                                "activeAccountHeaderRenderer": [
                                    "accountName": ["runs": [["text": ""]]],
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ])
        let brandAccountJSON = try JSONSerialization.data(withJSONObject: [
            "actions": [[
                "openPopupAction": [
                    "popup": [
                        "multiPageMenuRenderer": [
                            "header": [
                                "activeAccountHeaderRenderer": [
                                    "accountName": ["runs": [["text": "Brand"]]],
                                    "channelHandle": ["runs": [["text": "@brand"]]],
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ])

        var probed: [Int] = []
        let outcome = await discoverAccountSlots(maxAttempts: 8) { index in
            probed.append(index)
            switch index {
            case 0:
                return parseAccountMenuProbeResponse(validAccountJSON)
            case 1:
                return classifyAccountMenuHTTPStatus(408) ?? .unavailable
            case 2:
                return parseAccountMenuProbeResponse(malformedJSON)
            case 3:
                return parseAccountMenuProbeResponse(missingNameJSON)
            case 4:
                return parseAccountMenuProbeResponse(brandAccountJSON)
            default:
                return classifyAccountMenuHTTPStatus(404) ?? .unavailable
            }
        }

        #expect(probed == [0, 1, 2, 3, 4, 5])
        #expect(outcome.accounts == [
            DiscoveredAccountSlot(index: 0, name: "Primary", handle: "@primary"),
            DiscoveredAccountSlot(index: 4, name: "Brand", handle: "@brand"),
        ])
        #expect(outcome.transientFailures == [AccountSlotDiagnostic(index: 1, reason: "HTTP 408")])
        #expect(outcome.unknownResponses.map(\.index) == [2, 3])
        let apiTimeoutJSON = Data("{\"error\":{\"code\":408}}".utf8)
        #expect(parseAccountMenuProbeResponse(apiTimeoutJSON) == .transientFailure("API error 408"))
        let apiBadRequestJSON = Data("{\"error\":{\"code\":400}}".utf8)
        #expect(parseAccountMenuProbeResponse(apiBadRequestJSON) == .unknownResponse("API error 400"))
        let apiMissingCodeJSON = Data("{\"error\":{\"status\":\"INTERNAL\"}}".utf8)
        #expect(parseAccountMenuProbeResponse(apiMissingCodeJSON) == .unknownResponse("API error without status code"))
        #expect(parseAccountMenuProbeResponse(Data("[]".utf8)) == .unknownResponse("Invalid or non-object JSON response"))
        #expect(parseAccountMenuProbeResponse(Data("not-json".utf8)) == .unknownResponse("Invalid or non-object JSON response"))
        #expect(classifyAccountMenuHTTPStatus(405) == .unknownResponse("Unexpected HTTP 405"))
        #expect(classifyAccountMenuHTTPStatus(400) == .unknownResponse("Unexpected HTTP 400"))

        let unexpectedStatusOutcome = await discoverAccountSlots(maxAttempts: 4) { index in
            switch index {
            case 0:
                parseAccountMenuProbeResponse(validAccountJSON)
            case 1:
                classifyAccountMenuHTTPStatus(405) ?? .unavailable
            case 2:
                parseAccountMenuProbeResponse(brandAccountJSON)
            default:
                classifyAccountMenuHTTPStatus(404) ?? .unavailable
            }
        }
        #expect(unexpectedStatusOutcome.accounts.map(\.index) == [0, 2])
        #expect(unexpectedStatusOutcome.unknownResponses == [AccountSlotDiagnostic(index: 1, reason: "Unexpected HTTP 405")])
    }

    @Test("Saved-response summary redacts arbitrary dictionary and renderer keys")
    func savedResponseSummaryRedactsArbitraryKeys() {
        let keySentinel = "MOCK_TOKEN_KEY_SENTINEL_12345"
        let errorKeySummary = summarizeSavedResponse([
            "error": [keySentinel: NSNull()],
            "\(keySentinel)Renderer": ["nested": 1],
        ])
        #expect(!errorKeySummary.contains(keySentinel))
        let contentKeySummary = summarizeSavedResponse([
            "contents": [keySentinel: [keySentinel: 1]],
            "header": [keySentinel: 1],
            "\(keySentinel)Renderer": ["nested": 1],
        ])
        #expect(!contentKeySummary.contains(keySentinel))
    }

    @Test("DATASYNC_ID classification distinguishes primary, requested brand, other brand, absent, and malformed")
    func dataSyncIdClassification() {
        #expect(classifyDataSyncId("user123||", expectedBrandId: "brandA") == .primary)
        #expect(classifyDataSyncId("user123||", expectedBrandId: nil) == .primary)
        #expect(classifyDataSyncId("brandA||user123", expectedBrandId: "brandA") == .requestedBrand)
        #expect(classifyDataSyncId("brandB||user123", expectedBrandId: "brandA") == .otherBrand(length: 6))
        #expect(classifyDataSyncId("brandB||user123", expectedBrandId: nil) == .otherBrand(length: 6))
        #expect(classifyDataSyncId(nil, expectedBrandId: "brandA") == .absent)
        #expect(classifyDataSyncId("", expectedBrandId: "brandA") == .absent)
        #expect(classifyDataSyncId("||user123", expectedBrandId: "brandA") == .malformed)
        #expect(classifyDataSyncId("not-delimited", expectedBrandId: "brandA") == .malformed)
        #expect(classifyDataSyncId("a||b||c", expectedBrandId: "brandA") == .malformed)
    }
}
