import Foundation
import Testing
@testable import APIExplorer

@Suite("Lyrics probe request encoding")
struct LyricsProbeEncodingTests {
    @Test("Each query value round-trips punctuation, literal plus signs and Unicode")
    func queryValues() throws {
        let track = "Rock & Roll = Love+光"
        let artist = "A+B & Friends"
        let query = lyricsProbeEncodedQuery([
            URLQueryItem(name: "q_track", value: track),
            URLQueryItem(name: "q_artist", value: artist),
        ])
        let url = try #require(URL(string: "https://example.test/search?" + query))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [
            URLQueryItem(name: "q_track", value: track),
            URLQueryItem(name: "q_artist", value: artist),
        ])
        #expect(query.contains("%26"))
        #expect(query.contains("%3D"))
        #expect(query.contains("%2B"))
        #expect(query.split(separator: "&").count == 2)
    }

    @Test("Synthetic cookie fields become sorted key=value pairs, including empty values")
    func clientCookies() {
        let header = lyricsProbeCookieHeader(["os": "test-client", "__csrf": "", "appver": "test-version"])
        #expect(header == "__csrf=; appver=test-version; os=test-client")
        #expect(!header.contains("key:"))
        #expect(!header.contains("value:"))
    }
}
