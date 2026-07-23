import Foundation
import Testing
@testable import Kaset

/// Tests for normalizing WebView-reported artist bylines.
@Suite(.tags(.service))
@MainActor
struct PlayerServiceArtistNameTests {
    @Test("Strips a trailing view-count segment")
    func stripsViewCount() {
        #expect(PlayerService.normalizedWebArtistName("Artist • 1.3M views") == "Artist")
        #expect(PlayerService.normalizedWebArtistName("Artist • 1 view") == "Artist")
    }

    @Test("Leaves a plain artist name unchanged")
    func plainNameUnchanged() {
        #expect(PlayerService.normalizedWebArtistName("Artist") == "Artist")
    }

    @Test("Keeps non-view-count segments")
    func keepsOtherSegments() {
        #expect(PlayerService.normalizedWebArtistName("Song • Artist • 1.2M views") == "Song • Artist")
        #expect(PlayerService.normalizedWebArtistName("Primary Artist & Guest Artist • 1.2M views") == "Primary Artist & Guest Artist")
        #expect(PlayerService.normalizedWebArtistName("Artist • Topic") == "Artist • Topic")
    }

    @Test("Observer preserves the DOM fallback and prefers a structured artist")
    func observerArtistSelectionContract() {
        let script = SingletonPlayerWebView.observerScript
        #expect(script.contains("const domArtist = artistEl ? artistEl.textContent.trim() : '';"))
        #expect(script.contains("const artist = playerArtist || domArtist;"))
        #expect(!script.contains(".split(/\\s+•\\s+/u, 1)"))
    }

    @Test("Preserves artist names containing view")
    func preservesViewNames() {
        #expect(PlayerService.normalizedWebArtistName("Point of View • 1.3M views") == "Point of View")
        #expect(PlayerService.normalizedWebArtistName("The Views • Topic") == "The Views • Topic")
        #expect(PlayerService.normalizedWebArtistName("Metro Boomin • 21 Savage") == "Metro Boomin • 21 Savage")
    }

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(PlayerService.normalizedWebArtistName("  Artist • 500 views  ") == "Artist")
    }

    @Test("Leaves a single numeric-looking segment unchanged")
    func singleNumericSegmentUnchanged() {
        #expect(PlayerService.normalizedWebArtistName("1.3M views") == "1.3M views")
    }

    @Test("Same-video byline updates preserve resolved state and accept a thumbnail")
    func sameVideoBylinePreservesResolvedStateAndUpdatesThumbnail() {
        let playerService = PlayerService()
        let resolvedArtist = Artist(id: "UCresolved", name: "Artist")
        let thumbnailURL = URL(string: "https://example.com/artwork.jpg")
        let album = Album(
            id: "MPREalbum",
            title: "Album",
            artists: nil,
            thumbnailURL: nil,
            year: "2026",
            trackCount: nil
        )
        let song = Song(
            id: "video",
            title: "Unknown",
            artists: [resolvedArtist],
            album: album,
            videoId: "video",
            hasVideo: true,
            likeStatus: .like,
            isInLibrary: true,
            isExplicit: true,
            playlistSetVideoId: "playlist-item"
        )
        playerService.currentTrack = song
        playerService.currentTrackLikeStatus = .like
        playerService.currentTrackInLibrary = true

        playerService.updateTrackMetadata(
            title: "Resolved Song",
            artist: "Uploader Name • Topic",
            thumbnailUrl: thumbnailURL?.absoluteString ?? "",
            videoId: song.videoId
        )

        #expect(playerService.currentTrack?.id == song.id)
        #expect(playerService.currentTrack?.title == "Resolved Song")
        #expect(playerService.currentTrack?.artists == song.artists)
        #expect(playerService.currentTrack?.album == song.album)
        #expect(playerService.currentTrack?.thumbnailURL == thumbnailURL)
        #expect(playerService.currentTrack?.hasVideo == song.hasVideo)
        #expect(playerService.currentTrack?.likeStatus == song.likeStatus)
        #expect(playerService.currentTrack?.isInLibrary == song.isInLibrary)
        #expect(playerService.currentTrack?.isExplicit == song.isExplicit)
        #expect(playerService.currentTrack?.playlistSetVideoId == song.playlistSetVideoId)
        #expect(playerService.currentTrackLikeStatus == .like)
        #expect(playerService.currentTrackInLibrary)
    }

    @Test("Same-video placeholder titles do not replace a resolved title")
    func sameVideoPlaceholderTitlePreservesResolvedTitle() {
        for observedTitle in ["", "Loading..."] {
            let playerService = PlayerService()
            playerService.currentTrack = Song(
                id: "video",
                title: "Resolved Song",
                artists: [Artist(id: "UCresolved", name: "Artist")],
                videoId: "video"
            )

            playerService.updateTrackMetadata(
                title: observedTitle,
                artist: "Artist",
                thumbnailUrl: "",
                videoId: "video"
            )

            #expect(playerService.currentTrack?.title == "Resolved Song")
        }
    }

    @Test("A real WebView title refreshes the same resolved track")
    func realWebViewTitleRefreshesResolvedTrack() {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "video",
            title: "Clean Song",
            artists: [Artist(id: "UCresolved", name: "Artist")],
            videoId: "video"
        )

        playerService.updateTrackMetadata(
            title: "Clean Song (Official Video)",
            artist: "Artist",
            thumbnailUrl: "",
            videoId: "video"
        )

        #expect(playerService.currentTrack?.title == "Clean Song (Official Video)")
    }

    @Test("ID-less track transitions do not retain the previous resolved artist")
    func idlessTransitionReplacesResolvedArtist() {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "old-video",
            title: "Old Song",
            artists: [Artist(id: "UCold", name: "Old Artist")],
            videoId: "old-video"
        )

        playerService.updateTrackMetadata(
            title: "New Song",
            artist: "New Artist • 42 views",
            thumbnailUrl: "",
            videoId: nil
        )

        #expect(playerService.currentTrack?.title == "New Song")
        #expect(playerService.currentTrack?.artists == [Artist(id: "unknown", name: "New Artist")])
    }
}
