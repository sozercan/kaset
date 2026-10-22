import Foundation
import Testing
@testable import Kaset

/// Album playlist (OLAK) IDs load through their VL playlist page; a bare OLAK browse returns HTTP 400.
@Suite(.tags(.parser))
struct AlbumPlaylistBrowseTests {
    private static let albumPlaylistID = "OLAK5uy_lqcFZTOPHGwcnP0nYMzNuY0IES0fl7Fe4"
    private static let albumBrowseID = "MPREb_tQfaWH32ovE"

    @Test("Playlist browse IDs prefix PL and OLAK IDs with VL and keep the rest as-is")
    func playlistBrowseIDs() {
        #expect(YTMusicClient.playlistBrowseId(for: Self.albumPlaylistID) == "VL\(Self.albumPlaylistID)")
        #expect(YTMusicClient.playlistBrowseId(for: "PLTEST") == "VLPLTEST")
        #expect(YTMusicClient.playlistBrowseId(for: "VLPLTEST") == "VLPLTEST")
        #expect(YTMusicClient.playlistBrowseId(for: Self.albumBrowseID) == Self.albumBrowseID)
        #expect(YTMusicClient.playlistBrowseId(for: "RDCLAKTEST") == "RDCLAKTEST")
        #expect(YTMusicClient.playlistBrowseId(for: Playlist.uploadedSongsBrowseID) == Playlist.uploadedSongsBrowseID)
    }

    @Test("An album's VL playlist page parses its tracks and keeps the OLAK library target")
    func parseHeaderlessAlbumPlaylist() throws {
        let url = try #require(Bundle.module.url(forResource: "album_playlist_without_header", withExtension: "json"))
        let data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

        let detail = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: Self.albumPlaylistID).detail

        #expect(detail.isAlbum)
        #expect(detail.libraryTargetId == Self.albumPlaylistID)
        // The VL page has no album header; PlaylistDetailViewModel fills it from the route.
        #expect(detail.title == "Unknown Playlist")
        #expect(detail.tracks.map(\.videoId) == ["wqaKHHxQFZc", "cNavPZ8GA6I", "3HuXFfq79I8"])
        #expect(detail.tracks.first?.title == "Come Together (2019 Mix)")
        #expect(detail.tracks.first?.artistsDisplay == "The Beatles")
        #expect(detail.tracks.allSatisfy { $0.album?.id == Self.albumBrowseID })
    }
}
