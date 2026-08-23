import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.parser))
struct PlaylistEditabilityTests {
    @Test("Delete affordance is true for explicit delete endpoints")
    func canDeleteForExplicitDeleteEndpoint() {
        let response: [String: Any] = [
            "menu": [
                "menuRenderer": [
                    "items": [[
                        "menuNavigationItemRenderer": [
                            "navigationEndpoint": [
                                "deletePlaylistEndpoint": ["playlistId": "VL-owned"],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        #expect(PlaylistEditability.canDeletePlaylist(from: response))
    }

    @Test("Delete affordance is true for editable playlist headers")
    func canDeleteForEditableHeader() {
        let response: [String: Any] = [
            "musicEditablePlaylistDetailHeaderRenderer": [
                "title": ["runs": [["text": "Owned"]]],
            ],
        ]

        #expect(PlaylistEditability.canDeletePlaylist(from: response))
    }

    @Test("Unknown ownership is not deletable")
    func unknownOwnershipIsNotDeletable() {
        let response: [String: Any] = [
            "musicDetailHeaderRenderer": [
                "title": ["runs": [["text": "Saved Playlist"]]],
            ],
        ]

        #expect(!PlaylistEditability.canDeletePlaylist(from: response))
    }

    @Test("Delete affordance is true for delete command text")
    func canDeleteForDeleteCommandText() {
        let response: [String: Any] = [
            "menu": [
                "items": [[
                    "label": "music/playlist/delete",
                ]],
            ],
        ]

        #expect(PlaylistEditability.canDeletePlaylist(from: response))
    }
}
