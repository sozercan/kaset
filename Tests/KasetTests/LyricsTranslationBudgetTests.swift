import Foundation
@testable import Kaset
import Testing

@Suite(.tags(.model))
struct LyricsTranslationBudgetTests {
    @Test("Translation fragments preserve a long CJK line within the full encoded URL budget")
    func encodedLineBudget() throws {
        let text = String(repeating: "你好🌍 &+=", count: 400)
        let fragments = try GoogleTranslateService.fragments(for: text, target: "zh-Hant")
        #expect(fragments.count > 1)
        #expect(fragments.joined() == text)
        for fragment in fragments {
            let url = try GoogleTranslateService.requestURL(text: fragment, target: "zh-Hant")
            #expect(url.absoluteString.utf8.count <= 3500)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == fragment)
        }
        #expect(GoogleTranslateService.targetCode(for: nil) == "en")
        #expect(GoogleTranslateService.targetCode(for: "") == "en")
        #expect(GoogleTranslateService.targetCode(for: "zh-Hant") == "zh-TW")
    }
}
