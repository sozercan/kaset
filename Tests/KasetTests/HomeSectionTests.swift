import Foundation
import Testing
@testable import Kaset

/// Tests for HomeSection and HomeSectionItem.
@Suite("HomeSection")
struct HomeSectionTests {
    // MARK: - HomeSectionItem ID Tests

    @Test("Song item ID has correct prefix")
    func songItemId() {
        let song = Song(
            id: "video123",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "video123"
        )

        let item = HomeSectionItem.song(song)
        #expect(item.id == "song-video123")
    }

    @Test("Album item ID has correct prefix")
    func albumItemId() {
        let album = Album(
            id: "album456",
            title: "Test Album",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )

        let item = HomeSectionItem.album(album)
        #expect(item.id == "album-album456")
    }

    @Test("Playlist item ID has correct prefix")
    func playlistItemId() {
        let playlist = Playlist(
            id: "playlist789",
            title: "Test Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )

        let item = HomeSectionItem.playlist(playlist)
        #expect(item.id == "playlist-playlist789")
    }

    @Test("Artist item ID has correct prefix")
    func artistItemId() {
        let artist = Artist(id: "artist111", name: "Test Artist")

        let item = HomeSectionItem.artist(artist)
        #expect(item.id == "artist-artist111")
    }

    // MARK: - HomeSectionItem Title Tests

    @Test("Song item returns song title")
    func songItemTitle() {
        let song = Song(
            id: "1",
            title: "Amazing Song",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "1"
        )

        let item = HomeSectionItem.song(song)
        #expect(item.title == "Amazing Song")
    }

    @Test("Album item returns album title")
    func albumItemTitle() {
        let album = Album(
            id: "1",
            title: "Great Album",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )

        let item = HomeSectionItem.album(album)
        #expect(item.title == "Great Album")
    }

    @Test("Playlist item returns playlist title")
    func playlistItemTitle() {
        let playlist = Playlist(
            id: "1",
            title: "My Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )

        let item = HomeSectionItem.playlist(playlist)
        #expect(item.title == "My Playlist")
    }

    @Test("Artist item returns artist name")
    func artistItemTitle() {
        let artist = Artist(id: "1", name: "Famous Artist")

        let item = HomeSectionItem.artist(artist)
        #expect(item.title == "Famous Artist")
    }

    // MARK: - HomeSectionItem Subtitle Tests

    @Test("Song item subtitle shows artists")
    func songItemSubtitle() {
        let artists = [Artist(id: "a1", name: "Artist One"), Artist(id: "a2", name: "Artist Two")]
        let song = Song(
            id: "1",
            title: "Song",
            artists: artists,
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "1"
        )

        let item = HomeSectionItem.song(song)
        #expect(item.subtitle == "Artist One, Artist Two")
    }

    @Test("Album item subtitle shows artists")
    func albumItemSubtitle() {
        let artists = [Artist(id: "a1", name: "Album Artist")]
        let album = Album(
            id: "1",
            title: "Album",
            artists: artists,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )

        let item = HomeSectionItem.album(album)
        #expect(item.subtitle == "Album Artist")
    }

    @Test("Playlist item subtitle shows author")
    func playlistItemSubtitle() {
        let playlist = Playlist(
            id: "1",
            title: "Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: "Playlist Author"
        )

        let item = HomeSectionItem.playlist(playlist)
        #expect(item.subtitle == "Playlist Author")
    }

    @Test("Artist item subtitle is 'Artist'")
    func artistItemSubtitle() {
        let artist = Artist(id: "1", name: "Artist")

        let item = HomeSectionItem.artist(artist)
        #expect(item.subtitle == "Artist")
    }

    // MARK: - HomeSectionItem ThumbnailURL Tests

    @Test("Song item returns song thumbnail")
    func songItemThumbnailURL() {
        let url = URL(string: "https://example.com/song.jpg")
        let song = Song(
            id: "1",
            title: "Song",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: url,
            videoId: "1"
        )

        let item = HomeSectionItem.song(song)
        #expect(item.thumbnailURL == url)
    }

    @Test("Album item returns album thumbnail")
    func albumItemThumbnailURL() {
        let url = URL(string: "https://example.com/album.jpg")
        let album = Album(
            id: "1",
            title: "Album",
            artists: nil,
            thumbnailURL: url,
            year: nil,
            trackCount: nil
        )

        let item = HomeSectionItem.album(album)
        #expect(item.thumbnailURL == url)
    }

    @Test("Playlist item returns playlist thumbnail")
    func playlistItemThumbnailURL() {
        let url = URL(string: "https://example.com/playlist.jpg")
        let playlist = Playlist(
            id: "1",
            title: "Playlist",
            description: nil,
            thumbnailURL: url,
            trackCount: nil,
            author: nil
        )

        let item = HomeSectionItem.playlist(playlist)
        #expect(item.thumbnailURL == url)
    }

    @Test("Artist item returns artist thumbnail")
    func artistItemThumbnailURL() {
        let url = URL(string: "https://example.com/artist.jpg")
        let artist = Artist(id: "1", name: "Artist", thumbnailURL: url)

        let item = HomeSectionItem.artist(artist)
        #expect(item.thumbnailURL == url)
    }

    // MARK: - HomeSectionItem VideoId Tests

    @Test("Song item returns videoId")
    func songItemVideoId() {
        let song = Song(
            id: "1",
            title: "Song",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "playable_video"
        )

        let item = HomeSectionItem.song(song)
        #expect(item.videoId == "playable_video")
    }

    @Test("Album item has no videoId")
    func albumItemVideoId() {
        let album = Album(id: "1", title: "Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
        let item = HomeSectionItem.album(album)
        #expect(item.videoId == nil)
    }

    @Test("Playlist item has no videoId")
    func playlistItemVideoId() {
        let playlist = Playlist(id: "1", title: "Playlist", description: nil, thumbnailURL: nil, trackCount: nil, author: nil)
        let item = HomeSectionItem.playlist(playlist)
        #expect(item.videoId == nil)
    }

    @Test("Artist item has no videoId")
    func artistItemVideoId() {
        let artist = Artist(id: "1", name: "Artist")
        let item = HomeSectionItem.artist(artist)
        #expect(item.videoId == nil)
    }

    // MARK: - HomeSectionItem BrowseId Tests

    @Test("Song item has no browseId")
    func songItemBrowseId() {
        let song = Song(id: "1", title: "Song", artists: [], album: nil, duration: nil, thumbnailURL: nil, videoId: "1")
        let item = HomeSectionItem.song(song)
        #expect(item.browseId == nil)
    }

    @Test("Album item returns album ID as browseId")
    func albumItemBrowseId() {
        let album = Album(id: "album123", title: "Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
        let item = HomeSectionItem.album(album)
        #expect(item.browseId == "album123")
    }

    @Test("Playlist item returns playlist ID as browseId")
    func playlistItemBrowseId() {
        let playlist = Playlist(id: "playlist456", title: "Playlist", description: nil, thumbnailURL: nil, trackCount: nil, author: nil)
        let item = HomeSectionItem.playlist(playlist)
        #expect(item.browseId == "playlist456")
    }

    @Test("Artist item returns artist ID as browseId")
    func artistItemBrowseId() {
        let artist = Artist(id: "artist789", name: "Artist")
        let item = HomeSectionItem.artist(artist)
        #expect(item.browseId == "artist789")
    }

    // MARK: - HomeSectionItem Extraction Tests

    @Test("Playlist item extracts playlist")
    func playlistItemExtraction() {
        let playlist = Playlist(id: "PL1", title: "My Playlist", description: nil, thumbnailURL: nil, trackCount: 10, author: "Me")
        let item = HomeSectionItem.playlist(playlist)

        #expect(item.playlist != nil)
        #expect(item.playlist?.id == "PL1")
        #expect(item.playlist?.title == "My Playlist")
    }

    @Test("Album item extracts album")
    func albumItemExtraction() {
        let album = Album(id: "AL1", title: "My Album", artists: nil, thumbnailURL: nil, year: "2024", trackCount: nil)
        let item = HomeSectionItem.album(album)

        #expect(item.album != nil)
        #expect(item.album?.id == "AL1")
        #expect(item.album?.title == "My Album")
    }

    @Test("Non-playlist item returns nil for playlist")
    func nonPlaylistItemPlaylistExtraction() {
        let song = Song(id: "1", title: "Song", artists: [], album: nil, duration: nil, thumbnailURL: nil, videoId: "1")
        let item = HomeSectionItem.song(song)
        #expect(item.playlist == nil)
    }

    @Test("Non-album item returns nil for album")
    func nonAlbumItemAlbumExtraction() {
        let artist = Artist(id: "1", name: "Artist")
        let item = HomeSectionItem.artist(artist)
        #expect(item.album == nil)
    }

    // MARK: - HomeSection Tests

    @Test("HomeSection initializes correctly")
    func homeSectionInit() {
        let song = Song(id: "1", title: "Song", artists: [], album: nil, duration: nil, thumbnailURL: nil, videoId: "1")
        let items = [HomeSectionItem.song(song)]

        let section = HomeSection(id: "section1", title: "My Section", items: items)

        #expect(section.id == "section1")
        #expect(section.title == "My Section")
        #expect(section.items.count == 1)
        #expect(!section.isChart)
    }

    @Test("HomeSection isChart flag works")
    func homeSectionIsChart() {
        let section = HomeSection(id: "charts", title: "Top Charts", items: [], isChart: true)
        #expect(section.isChart)
    }

    // MARK: - HomeResponse Tests

    @Test("HomeResponse is empty with no sections")
    func homeResponseIsEmptyWithNoSections() {
        let response = HomeResponse(sections: [])
        #expect(response.isEmpty)
    }

    @Test("HomeResponse is empty with empty items")
    func homeResponseIsEmptyWithEmptyItems() {
        let section = HomeSection(id: "1", title: "Empty Section", items: [])
        let response = HomeResponse(sections: [section])
        #expect(response.isEmpty)
    }

    @Test("HomeResponse is not empty with items")
    func homeResponseNotEmpty() {
        let song = Song(id: "1", title: "Song", artists: [], album: nil, duration: nil, thumbnailURL: nil, videoId: "1")
        let section = HomeSection(id: "1", title: "Section", items: [.song(song)])
        let response = HomeResponse(sections: [section])
        #expect(!response.isEmpty)
    }

    @Test("HomeResponse.empty returns empty response")
    func homeResponseEmptyStatic() {
        let empty = HomeResponse.empty
        #expect(empty.isEmpty)
        #expect(empty.sections.isEmpty)
    }
}
