import Testing
@testable import Kaset

struct CounterpartMetadataTests {
    @Test("Single-track and radio parsing share sibling classification", arguments: [true, false])
    func sharedClassification(videoPrimary: Bool) {
        let primary = Self.renderer(id: "primary", video: videoPrimary)
        let sibling = Self.renderer(id: "sibling", video: !videoPrimary)
        let wrapper: [String: Any] = ["counterpart": [["counterpartRenderer": ["playlistPanelVideoRenderer": sibling]]]]
        let ids = SongMetadataParser.counterpartIds(primary: primary, counterpart: SongMetadataParser.counterpartRenderer(in: wrapper))
        #expect(ids.audio == (videoPrimary ? "sibling" : nil))
        #expect(ids.companion == (videoPrimary ? nil : "sibling"))
        let duplicate = SongMetadataParser.counterpartIds(primary: primary, counterpart: primary)
        #expect(duplicate.audio == nil && duplicate.companion == nil)
    }

    private static func renderer(id: String, video: Bool) -> [String: Any] {
        ["videoId": id, "navigationEndpoint": ["watchEndpoint": ["watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": video ? "MUSIC_VIDEO_TYPE_OMV" : "MUSIC_VIDEO_TYPE_ATV"]]]]]
    }
}
