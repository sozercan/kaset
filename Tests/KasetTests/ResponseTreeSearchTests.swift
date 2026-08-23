import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.parser))
struct ResponseTreeSearchTests {
    @Test("Finds first nested dictionary by key")
    func findsFirstNestedDictionaryByKey() {
        let response: [String: Any] = [
            "outer": [
                "items": [
                    ["ignored": true],
                    ["targetRenderer": ["title": "Match"]],
                ],
            ],
        ]

        let dictionary = ResponseTreeSearch.firstDictionary(named: "targetRenderer", in: response)

        #expect(dictionary?["title"] as? String == "Match")
    }

    @Test("Detects nested keys and case-insensitive text")
    func detectsNestedKeysAndText() {
        let response: [String: Any] = [
            "actions": [[
                "command": [
                    "deletePlaylistEndpoint": ["playlistId": "VL123"],
                    "label": "Playlist/Delete",
                ],
            ]],
        ]

        #expect(ResponseTreeSearch.containsKey("deletePlaylistEndpoint", in: response))
        #expect(ResponseTreeSearch.containsText("playlist/delete", in: response))
        #expect(!ResponseTreeSearch.containsKey("createPlaylistEndpoint", in: response))
    }

    @Test("Detects nested key or text in one pass")
    func detectsNestedKeyOrTextInOnePass() {
        let response: [String: Any] = [
            "outer": [[
                "command": [
                    "label": "Playlist/Delete",
                ],
            ]],
        ]

        #expect(ResponseTreeSearch.containsAny(keys: ["missingRenderer"], text: "playlist/delete", in: response))
        #expect(!ResponseTreeSearch.containsAny(keys: ["missingRenderer"], text: "not-present", in: response))
    }
}
