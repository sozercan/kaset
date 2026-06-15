import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct QueueSongMetadataTests {
    @Test("Cleaned artists drop generic Album label and preserve metadata")
    func cleanedArtistsDropAlbumLabelAndPreserveMetadata() {
        let thumbnailURL = URL(string: "https://example.com/artist.jpg")
        let genericArtist = Artist(id: "generic", name: "Album", thumbnailURL: thumbnailURL, subtitle: "ignored", profileKind: .profile)
        let prefixedArtist = Artist(id: "artist", name: "Album, Real Artist", thumbnailURL: thumbnailURL, subtitle: "subtitle", profileKind: .artist)

        #expect(QueueSongMetadata.cleanedArtistPreservingMetadata(genericArtist) == nil)

        let cleanedArtist = QueueSongMetadata.cleanedArtistPreservingMetadata(prefixedArtist)
        #expect(cleanedArtist?.id == "artist")
        #expect(cleanedArtist?.name == "Real Artist")
        #expect(cleanedArtist?.thumbnailURL == thumbnailURL)
        #expect(cleanedArtist?.subtitle == "subtitle")
        #expect(cleanedArtist?.profileKind == .artist)
    }

    @Test("Queue songs use fallback artist album and thumbnail while preserving playback metadata")
    func queueSongsUseFallbacksAndPreserveMetadata() {
        let fallbackAlbum = Album(
            id: "MPRE-fallback",
            title: "Fallback Album",
            artists: [Artist(id: "album-artist", name: "Album Artist")],
            thumbnailURL: URL(string: "https://example.com/album.jpg"),
            year: "2024",
            trackCount: 2
        )
        let song = Song(
            id: "song-1",
            title: "Song 1",
            artists: [Artist(id: "generic", name: "Album")],
            duration: 120,
            videoId: "video-1",
            isPlayable: false,
            hasVideo: true,
            musicVideoType: .omv,
            likeStatus: .like,
            isInLibrary: true,
            isExplicit: true
        )

        let preparedSong = QueueSongMetadata.songsForQueue(
            [song],
            fallbackArtist: "Album, Fallback Artist",
            fallbackAlbum: fallbackAlbum
        ).first

        #expect(preparedSong?.artists.map(\.name) == ["Fallback Artist"])
        #expect(preparedSong?.album == fallbackAlbum)
        #expect(preparedSong?.thumbnailURL == fallbackAlbum.thumbnailURL)
        #expect(preparedSong?.isPlayable == false)
        #expect(preparedSong?.hasVideo == true)
        #expect(preparedSong?.musicVideoType == .omv)
        #expect(preparedSong?.likeStatus == .like)
        #expect(preparedSong?.isInLibrary == true)
        #expect(preparedSong?.isExplicit == true)
    }

    @Test("Album playback songs preserve album year and use loaded track count")
    func albumPlaybackSongsPreserveAlbumYearAndLoadedTrackCount() {
        let album = TestFixtures.makeAlbum(id: "MPRE-album", title: "Album Title", artistName: "Album, Album Artist", year: "1999")
        let track = Song(
            id: "track-1",
            title: "Track 1",
            artists: [],
            thumbnailURL: nil,
            videoId: "track-1"
        )

        let preparedTrack = QueueSongMetadata.albumSongs(
            [track],
            album: album,
            purpose: .playback(trackCount: 1)
        ).first

        #expect(preparedTrack?.artists.map(\.name) == ["Album Artist"])
        #expect(preparedTrack?.album?.id == "MPRE-album")
        #expect(preparedTrack?.album?.title == "Album Title")
        #expect(preparedTrack?.album?.artists?.map(\.name) == ["Album Artist"])
        #expect(preparedTrack?.album?.year == "1999")
        #expect(preparedTrack?.album?.trackCount == 1)
        #expect(preparedTrack?.thumbnailURL == album.thumbnailURL)
    }
}
