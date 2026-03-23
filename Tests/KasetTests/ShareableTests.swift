import Testing
@testable import Kaset

// MARK: - ShareableTests

@Suite("Shareable Protocol Tests")
struct ShareableTests {
    // MARK: - Song Tests

    @Test("Song shareText includes title and artist")
    func songShareText() {
        let song = Song(
            id: "test-song",
            title: "Never Gonna Give You Up",
            artists: [Artist(id: "UC-test", name: "Rick Astley")],
            videoId: "dQw4w9WgXcQ"
        )

        #expect(song.shareText == "Never Gonna Give You Up by Rick Astley")
    }

    @Test("Song shareURL has correct format")
    func songShareURL() {
        let song = Song(
            id: "test-song",
            title: "Test Song",
            artists: [Artist(id: "artist1", name: "Test Artist")],
            videoId: "dQw4w9WgXcQ"
        )

        #expect(song.shareURL?.absoluteString == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test("Song with multiple artists displays comma-separated")
    func songMultipleArtists() {
        let song = Song(
            id: "test-song",
            title: "Collaboration Track",
            artists: [
                Artist(id: "artist1", name: "Artist One"),
                Artist(id: "artist2", name: "Artist Two"),
                Artist(id: "artist3", name: "Artist Three"),
            ],
            videoId: "test123"
        )

        #expect(song.shareText == "Collaboration Track by Artist One, Artist Two, Artist Three")
    }

    // MARK: - Playlist Tests

    @Test("Playlist shareText includes title and author")
    func playlistShareText() {
        let playlist = Playlist(
            id: "PLtest123",
            title: "My Favorites",
            description: nil,
            thumbnailURL: nil,
            trackCount: 10,
            author: "John"
        )

        #expect(playlist.shareText == "My Favorites by John")
    }

    @Test("Playlist shareURL has correct format")
    func playlistShareURL() {
        let playlist = Playlist(
            id: "PLtest123",
            title: "Test Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 5,
            author: "Test Author"
        )

        #expect(playlist.shareURL?.absoluteString == "https://music.youtube.com/playlist?list=PLtest123")
    }

    @Test("Playlist without author shows only title")
    func playlistNoAuthor() {
        let playlist = Playlist(
            id: "PLtest",
            title: "No Author Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 3,
            author: nil
        )

        #expect(playlist.shareText == "No Author Playlist")
    }

    // MARK: - Album Tests

    @Test("Album with MPRE prefix has shareURL")
    func albumShareURL_MPRE() {
        let album = Album(
            id: "MPREb_test123",
            title: "Thriller",
            artists: [Artist(id: "artist1", name: "Michael Jackson")],
            thumbnailURL: nil,
            year: "1982",
            trackCount: 9
        )

        #expect(album.shareURL?.absoluteString == "https://music.youtube.com/browse/MPREb_test123")
        #expect(album.shareText == "Thriller by Michael Jackson")
    }

    @Test("Album with OLAK prefix has shareURL")
    func albumShareURL_OLAK() {
        let album = Album(
            id: "OLAK5uy_test456",
            title: "Test Album",
            artists: [Artist(id: "artist1", name: "Test Artist")],
            thumbnailURL: nil,
            year: "2023",
            trackCount: 12
        )

        #expect(album.shareURL?.absoluteString == "https://music.youtube.com/browse/OLAK5uy_test456")
    }

    @Test("Album with UUID ID has nil shareURL")
    func albumShareURL_UUID() {
        let album = Album(
            id: "550e8400-e29b-41d4-a716-446655440000",
            title: "Non-Navigable Album",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )

        #expect(album.shareURL == nil)
    }

    @Test("Album without artists shows only title")
    func albumNoArtists() {
        let album = Album(
            id: "MPREb_test",
            title: "Solo Album",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )

        #expect(album.shareText == "Solo Album")
    }

    // MARK: - Artist Tests

    @Test("Artist with UC prefix has shareURL")
    func artistShareURL_valid() {
        let artist = Artist(
            id: "UCuAXFkgsw1L7xaCfnd5JJOw",
            name: "Taylor Swift",
            thumbnailURL: nil
        )

        #expect(artist.shareURL?.absoluteString == "https://music.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(artist.shareText == "Taylor Swift")
    }

    @Test("Artist with UUID ID has nil shareURL")
    func artistShareURL_UUID() {
        let artist = Artist(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Unknown Artist",
            thumbnailURL: nil
        )

        #expect(artist.shareURL == nil)
    }

    @Test("Artist without UC prefix has nil shareURL")
    func artistShareURL_invalidPrefix() {
        let artist = Artist(
            id: "some-other-id",
            name: "Invalid Artist",
            thumbnailURL: nil
        )

        #expect(artist.shareURL == nil)
    }

    @Test("Artist shareSubtitle is nil")
    func artistShareSubtitle() {
        let artist = Artist(
            id: "UCtest",
            name: "Test Artist",
            thumbnailURL: nil
        )

        #expect(artist.shareSubtitle == nil)
        #expect(artist.shareText == "Test Artist")
    }
}
