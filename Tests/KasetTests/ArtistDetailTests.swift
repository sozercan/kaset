import Foundation
import Testing
@testable import Kaset

/// Tests for ArtistDetail.
@Suite(.tags(.viewModel))
struct ArtistDetailTests {
    @Test("ArtistDetail initialization")
    func artistDetailInit() {
        let artist = Artist(id: "UC123", name: "Test Artist", thumbnailURL: URL(string: "https://example.com/a.jpg"))
        let songs = [
            Song(id: "s1", title: "Song 1", artists: [artist], album: nil, duration: 180, thumbnailURL: nil, videoId: "s1"),
            Song(id: "s2", title: "Song 2", artists: [artist], album: nil, duration: 200, thumbnailURL: nil, videoId: "s2"),
        ]
        let albums = [
            Album(id: "a1", title: "Album 1", artists: [artist], thumbnailURL: nil, year: "2023", trackCount: 10),
        ]

        let detail = ArtistDetail(
            artist: artist,
            description: "A great artist",
            songs: songs,
            albumSections: [AlbumCarouselSection(title: "Albums", albums: albums)],
            thumbnailURL: URL(string: "https://example.com/large.jpg")
        )

        #expect(detail.id == "UC123")
        #expect(detail.name == "Test Artist")
        #expect(detail.description == "A great artist")
        #expect(detail.songs.count == 2)
        #expect(detail.albumSections.first?.albums.count == 1)
        #expect(detail.playlistSections.isEmpty)
        #expect(detail.artistSections.isEmpty)
        #expect(detail.thumbnailURL?.absoluteString == "https://example.com/large.jpg")
    }

    @Test("ArtistDetail id computed property")
    func artistDetailIdComputedProperty() {
        let artist = Artist(id: "artist_id_123", name: "Artist")
        let detail = ArtistDetail(artist: artist, description: nil, songs: [], thumbnailURL: nil)
        #expect(detail.id == "artist_id_123")
    }

    @Test("ArtistDetail name computed property")
    func artistDetailNameComputedProperty() {
        let artist = Artist(id: "1", name: "Famous Artist Name")
        let detail = ArtistDetail(artist: artist, description: nil, songs: [], thumbnailURL: nil)
        #expect(detail.name == "Famous Artist Name")
    }

    @Test("ArtistDetail with no description")
    func artistDetailWithNoDescription() {
        let artist = Artist(id: "1", name: "Artist")
        let detail = ArtistDetail(artist: artist, description: nil, songs: [], thumbnailURL: nil)
        #expect(detail.description == nil)
    }

    @Test("ArtistDetail with empty songs and albums")
    func artistDetailWithEmptySongsAndAlbums() {
        let artist = Artist(id: "1", name: "New Artist")
        let detail = ArtistDetail(artist: artist, description: "Just starting out", songs: [], thumbnailURL: nil)
        #expect(detail.songs.isEmpty)
        #expect(detail.albumSections.isEmpty)
        #expect(detail.playlistSections.isEmpty)
        #expect(detail.artistSections.isEmpty)
    }

    @Test("ArtistDetail artist property")
    func artistDetailArtistProperty() {
        let artist = Artist(id: "UC123", name: "Artist", thumbnailURL: URL(string: "https://example.com/thumb.jpg"))
        let detail = ArtistDetail(artist: artist, description: nil, songs: [], thumbnailURL: nil)

        #expect(detail.artist.id == "UC123")
        #expect(detail.artist.name == "Artist")
        #expect(detail.artist.thumbnailURL != nil)
    }

    @Test("ArtistDetail formats monthly audience for English")
    func artistDetailFormatsMonthlyAudienceEnglish() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            monthlyAudience: "2.59M"
        )

        #expect(detail.audienceSubtitle(languageCode: "en") == "2.59M monthly audience")
    }

    @Test("ArtistDetail formats monthly audience for Turkish")
    func artistDetailFormatsMonthlyAudienceTurkish() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            monthlyAudience: "2.59M"
        )

        #expect(detail.audienceSubtitle(languageCode: "tr") == "Aylık kitle: 2,59 Mn")
    }

    @Test("ArtistDetail formats monthly audience for Arabic")
    func artistDetailFormatsMonthlyAudienceArabic() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            monthlyAudience: "2.59M"
        )

        #expect(detail.audienceSubtitle(languageCode: "ar") == "2.59 مليون مشاهد شهريًا")
    }

    @Test("ArtistDetail formats monthly audience for Korean")
    func artistDetailFormatsMonthlyAudienceKorean() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            monthlyAudience: "2.59M"
        )

        #expect(detail.audienceSubtitle(languageCode: "ko") == "월간 시청자 259만명")
    }

    @Test("ArtistDetail audience subtitle does not fall back to subscriber count")
    func artistDetailAudienceSubtitleDoesNotFallbackToSubscriberCount() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            subscriberCount: "203K subscribers"
        )

        #expect(detail.audienceSubtitle(languageCode: "tr") == nil)
    }

    @Test("ArtistDetail formats subscriber count for Turkish")
    func artistDetailFormatsSubscriberCountTurkish() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            subscriberCount: "203K subscribers"
        )

        #expect(detail.formattedSubscriberCount(languageCode: "tr") == "203 B")
    }

    @Test("ArtistDetail formats subscriber count for Arabic")
    func artistDetailFormatsSubscriberCountArabic() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            subscriberCount: "203K subscribers"
        )

        #expect(detail.formattedSubscriberCount(languageCode: "ar") == "203 ألف")
    }

    @Test("ArtistDetail formats subscriber count for Korean")
    func artistDetailFormatsSubscriberCountKorean() {
        let detail = ArtistDetail(
            artist: Artist(id: "1", name: "BEGE"),
            description: nil,
            songs: [],
            thumbnailURL: nil,
            subscriberCount: "203K subscribers"
        )

        #expect(detail.formattedSubscriberCount(languageCode: "ko") == "20.3만")
    }

    @Test("Artist formats monthly audience subtitle for Turkish")
    func artistFormatsMonthlyAudienceSubtitleTurkish() {
        let artist = Artist(id: "1", name: "Ezhel", subtitle: "24.9M monthly audience")

        #expect(artist.formattedSubtitle(languageCode: "tr") == "Aylık kitle: 24,9 Mn")
    }

    @Test("Artist formats subscriber subtitle for Korean")
    func artistFormatsSubscriberSubtitleKorean() {
        let artist = Artist(id: "1", name: "Profile", subtitle: "919 subscribers")

        #expect(artist.formattedSubtitle(languageCode: "ko") == "919")
    }
}
