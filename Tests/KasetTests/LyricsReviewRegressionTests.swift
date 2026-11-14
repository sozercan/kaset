import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct LyricsReviewRegressionTests {
    @Test("CJK lyrics match across spacing, punctuation, line breaks and character width")
    func cjkSimilarity() {
        #expect(LyricsSimilarity.similarity("也许已经\n不再想起你", "也许 已经，不再想起你") > 0.9)
        #expect(LyricsSimilarity.similarity("君の夢を見た\nＡＢＣ", "君 の夢を見た ABC") > 0.9)
        #expect(LyricsSimilarity.similarity("안녕하세요 세계", "안녕 하세요\n세계") > 0.9)
        #expect(LyricsSimilarity.similarity("你好世界", "完全不同") == 0)
    }

    @Test("Long CJK and emoji lyric lines stay inside the full encoded URL budget")
    func encodedTranslationFragments() throws {
        let text = String(repeating: "你好🌍 &+=", count: 400)
        let fragments = try GoogleTranslateService.fragments(for: text, target: "zh-TW")
        #expect(fragments.count > 1)
        #expect(fragments.joined() == text)
        for fragment in fragments {
            let url = try GoogleTranslateService.requestURL(text: fragment, target: "zh-TW")
            #expect(url.absoluteString.utf8.count <= 3500)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == fragment)
        }
        #expect(GoogleTranslateService.targetCode(for: "") == "en")
        #expect(GoogleTranslateService.targetCode(for: "zh-TW") == "zh-TW")
    }

    @Test("Strict KuGou matching rejects recordings accepted under the normal tolerance")
    func kuGouDuration() {
        #expect(KuGouProvider.durationMatches(187, target: 180, requiresCloseDurationMatch: false))
        #expect(!KuGouProvider.durationMatches(187, target: 180, requiresCloseDurationMatch: true))
        #expect(!KuGouProvider.durationMatches(180, target: .nan, requiresCloseDurationMatch: true))
    }

    @Test("NetEase never falls back to an unrelated or wrong-duration song")
    func netEaseCandidates() {
        let songs = [NetEaseProvider.SearchResponse.Song(id: 1, name: "Other", duration: 180_000, artists: [.init(name: "Artist")]), NetEaseProvider.SearchResponse.Song(id: 2, name: "Target", duration: 187_000, artists: [.init(name: "Artist")])]
        #expect(NetEaseProvider.matchSongID(songs, title: "Target", artist: "Wrong Singer", duration: 187, requiresCloseDurationMatch: false) == nil)
        #expect(NetEaseProvider.matchSongID(songs, title: "Missing", artist: "Artist", duration: 180, requiresCloseDurationMatch: false) == nil)
        #expect(NetEaseProvider.matchSongID(songs, title: "Target", artist: "Artist", duration: 180, requiresCloseDurationMatch: false) == 2)
        #expect(NetEaseProvider.matchSongID(songs, title: "Target", artist: "Artist", duration: 180, requiresCloseDurationMatch: true) == nil)
        #expect(NetEaseProvider.matchSongID(songs, title: "Target", artist: "Artist", duration: 100, requiresCloseDurationMatch: false) == nil)
    }
}
