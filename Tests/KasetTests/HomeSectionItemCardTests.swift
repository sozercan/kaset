import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
@MainActor
struct HomeSectionItemCardTests {
    enum SongChange: CaseIterable {
        case id
        case title
        case artists
        case album
        case duration
        case thumbnail
        case isPlayable
        case hasVideo
        case musicVideoType
        case likeStatus
        case isInLibrary
        case feedbackTokens
        case isExplicit
        case playlistSetVideoId
        case audioTrackVideoId
    }

    enum ItemKind: CaseIterable {
        case song
        case album
        case playlist
        case artist
    }

    @Test("Song metadata updates invalidate a card with the same playback identity", arguments: SongChange.allCases)
    func songMetadataChanges(change: SongChange) {
        let original = Self.song()
        let updated = Self.song(change: change)

        #expect(original == updated)
        #expect(Self.card(.song(original)) != Self.card(.song(updated)))
    }

    @Test("Unchanged items still skip card updates", arguments: ItemKind.allCases)
    func unchangedItems(kind: ItemKind) {
        let item = Self.item(kind, title: "Original")

        #expect(Self.card(item) == Self.card(item))
    }

    @Test("Metadata updates invalidate each kind of card", arguments: ItemKind.allCases)
    func itemMetadataChanges(kind: ItemKind) {
        let original = Self.item(kind, title: "Original")
        let updated = Self.item(kind, title: "Updated")

        #expect(original.id == updated.id)
        #expect(Self.card(original) != Self.card(updated))
    }

    @Test("Rank updates invalidate a card")
    func rankChanges() {
        let item = HomeSectionItem.song(Self.song())
        let unranked = HomeSectionItemCard(item: item, action: {})
        let first = HomeSectionItemCard(item: item, rank: 1, action: {})
        let second = HomeSectionItemCard(item: item, rank: 2, action: {})

        #expect(unranked != first)
        #expect(first != second)
    }

    @Test("Playlist play action availability participates in equality")
    func playActionAvailability() {
        let item = Self.item(.playlist, title: "Playlist")
        let withoutPlay = HomeSectionItemCard(item: item, action: {})
        let withPlay = HomeSectionItemCard(item: item, playAction: {}, action: {})
        let rebuiltWithPlay = HomeSectionItemCard(item: item, playAction: {}, action: {})

        #expect(withoutPlay != withPlay)
        #expect(withPlay == rebuiltWithPlay)
    }

    private static func card(_ item: HomeSectionItem) -> HomeSectionItemCard {
        HomeSectionItemCard(item: item, action: {})
    }

    private static func song(change: SongChange? = nil) -> Song {
        Song(
            id: change == .id ? "updated-id" : "song-id",
            title: change == .title ? "Updated" : "Original",
            artists: [Artist(id: "artist-id", name: change == .artists ? "Updated artist" : "Artist")],
            album: change == .album ? self.album(title: "Album") : nil,
            duration: change == .duration ? 240 : 180,
            thumbnailURL: URL(string: change == .thumbnail ? "https://example.com/updated.jpg" : "https://example.com/original.jpg"),
            videoId: "video-id",
            isPlayable: change != .isPlayable,
            hasVideo: change == .hasVideo ? true : nil,
            musicVideoType: change == .musicVideoType ? .omv : .atv,
            likeStatus: change == .likeStatus ? .like : nil,
            isInLibrary: change == .isInLibrary ? true : nil,
            feedbackTokens: change == .feedbackTokens ? FeedbackTokens(add: "mock-token", remove: nil) : nil,
            isExplicit: change == .isExplicit ? true : nil,
            playlistSetVideoId: change == .playlistSetVideoId ? "playlist-entry-id" : nil,
            audioTrackVideoId: change == .audioTrackVideoId ? "audio-video-id" : nil
        )
    }

    private static func item(_ kind: ItemKind, title: String) -> HomeSectionItem {
        switch kind {
        case .song:
            .song(self.song().replacingDisplayMetadata(title: title, artists: [], thumbnailURL: nil))
        case .album:
            .album(self.album(title: title))
        case .playlist:
            .playlist(Playlist(id: "playlist-id", title: title, description: nil, thumbnailURL: nil, trackCount: nil))
        case .artist:
            .artist(Artist(id: "artist-id", name: title))
        }
    }

    private static func album(title: String) -> Album {
        Album(id: "album-id", title: title, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
    }
}
