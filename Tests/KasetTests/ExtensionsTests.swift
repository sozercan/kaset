import Foundation
import Testing
@testable import Kaset

/// Tests for utility extensions.
@Suite(.tags(.model))
struct ExtensionsTests {
    // MARK: - Collection Safe Subscript Tests

    @Test("Safe subscript returns value for valid indices")
    func arraySafeSubscriptInBounds() {
        let array = [1, 2, 3, 4, 5]
        #expect(array[safe: 0] == 1)
        #expect(array[safe: 2] == 3)
        #expect(array[safe: 4] == 5)
    }

    @Test("Safe subscript returns nil for out of bounds indices")
    func arraySafeSubscriptOutOfBounds() {
        let array = [1, 2, 3]
        #expect(array[safe: 3] == nil)
        #expect(array[safe: 10] == nil)
        #expect(array[safe: -1] == nil)
    }

    @Test("Safe subscript returns nil for empty array")
    func arraySafeSubscriptEmptyArray() {
        let array: [Int] = []
        #expect(array[safe: 0] == nil)
    }

    @Test("Safe subscript works with character arrays")
    func stringSafeSubscript() {
        let string = "Hello"
        let array = Array(string)
        #expect(array[safe: 0] == "H")
        #expect(array[safe: 4] == "o")
        #expect(array[safe: 5] == nil)
    }

    // MARK: - TimeInterval Formatted Duration Tests

    @Test(
        "Formats seconds correctly",
        arguments: [
            (0.0, "0:00"),
            (5.0, "0:05"),
            (59.0, "0:59"),
        ]
    )
    func formattedDurationSeconds(seconds: TimeInterval, expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test(
        "Formats minutes correctly",
        arguments: [
            (60.0, "1:00"),
            (65.0, "1:05"),
            (125.0, "2:05"),
            (3599.0, "59:59"),
        ]
    )
    func formattedDurationMinutes(seconds: TimeInterval, expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test(
        "Formats hours correctly",
        arguments: [
            (3600.0, "1:00:00"),
            (3661.0, "1:01:01"),
            (7325.0, "2:02:05"),
            (36000.0, "10:00:00"),
        ]
    )
    func formattedDurationHours(seconds: TimeInterval, expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test("Truncates decimal seconds")
    func formattedDurationDecimal() {
        #expect(TimeInterval(65.5).formattedDuration == "1:05")
        #expect(TimeInterval(65.9).formattedDuration == "1:05")
    }

    // MARK: - URL High Quality Thumbnail Tests

    @Test("Upgrades ytimg URL to high quality")
    func highQualityThumbnailYtimg() throws {
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/w60-h60-l90-rj"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality != nil)
        #expect(try #require(highQuality?.absoluteString.contains("w226-h226")))
    }

    @Test("Upgrades googleusercontent URL to high quality")
    func highQualityThumbnailGoogleusercontent() throws {
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality != nil)
        #expect(try #require(highQuality?.absoluteString.contains("w226-h226")))
    }

    @Test("Returns original URL for non-YouTube URLs")
    func highQualityThumbnailNonYouTubeURL() throws {
        let url = try #require(URL(string: "https://example.com/image.jpg"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality == url)
    }

    @Test("Returns same URL for already high quality thumbnails")
    func highQualityThumbnailAlreadyHighQuality() throws {
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/w400-h400-l90-rj"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality?.absoluteString == "https://i.ytimg.com/vi/abc/w400-h400-l90-rj")
    }

    // MARK: - URL Square Thumbnail Tests

    @Test(
        "Rewrites any size segment to the requested square side",
        arguments: [
            "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj",
            "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj",
            "https://i.ytimg.com/vi/abc/w226-h226-l90-rj",
        ]
    )
    func squareThumbnailRewritesSizeSegment(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        let resized = url.squareThumbnailURL(side: 544)
        #expect(try #require(resized?.absoluteString.contains("w544-h544")))
    }

    @Test("Returns original URL for non-Google hosts")
    func squareThumbnailNonGoogleHost() throws {
        let url = try #require(URL(string: "https://example.com/image-w60-h60.jpg"))
        #expect(url.squareThumbnailURL(side: 544) == url)
    }

    @Test("Leaves Google URLs without a size segment unchanged")
    func squareThumbnailNoSizeSegment() throws {
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        #expect(url.squareThumbnailURL(side: 544)?.absoluteString == url.absoluteString)
    }

    @Test("Song.largeThumbnailURL falls back to public thumbnail when API URL is missing")
    func largeThumbnailFallback() {
        let song = Song(id: "vid123", title: "Test", artists: [], videoId: "vid123")
        #expect(song.largeThumbnailURL == song.fallbackThumbnailURL)
    }

    @Test("Song.largeThumbnailURL upgrades API thumbnail to 544px")
    func largeThumbnailUpgradesSize() throws {
        let song = Song(
            id: "vid123",
            title: "Test",
            artists: [],
            thumbnailURL: URL(string: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"),
            videoId: "vid123"
        )
        #expect(try #require(song.largeThumbnailURL?.absoluteString.contains("w544-h544")))
    }

    // MARK: - String Truncated Tests

    @Test("Returns full string when shorter than limit")
    func stringTruncatedShorterThanLimit() {
        let string = "Hello"
        #expect(string.truncated(to: 10) == "Hello")
    }

    @Test("Returns full string when exactly at limit")
    func stringTruncatedExactlyAtLimit() {
        let string = "Hello"
        #expect(string.truncated(to: 5) == "Hello")
    }

    @Test("Truncates with ellipsis when longer than limit")
    func stringTruncatedLongerThanLimit() {
        let string = "Hello, World!"
        #expect(string.truncated(to: 5) == "Hello…")
    }

    @Test("Uses custom trailing string")
    func stringTruncatedWithCustomTrailing() {
        let string = "Hello, World!"
        #expect(string.truncated(to: 5, trailing: "...") == "Hello...")
    }

    @Test("Handles empty string")
    func stringTruncatedEmptyString() {
        let string = ""
        #expect(string.truncated(to: 10).isEmpty)
    }

    @Test("Handles zero length")
    func stringTruncatedZeroLength() {
        let string = "Hello"
        #expect(string.truncated(to: 0) == "…")
    }

    @Test("Handles one character")
    func stringTruncatedOneCharacter() {
        let string = "Hello"
        #expect(string.truncated(to: 1) == "H…")
    }
}
