import Foundation
import Testing
@testable import YouTubeAskCore

@Suite("YouTubeAsk visible-text sanitizer")
struct YouTubeAskVisibleTextSanitizerTests {
    @Test("Preserves localized visible text while removing controls and bidi formatting")
    func preservesLocalizedText() throws {
        let bidiOverride = try #require(UnicodeScalar(0x202E))
        let input = "  مرحبًا \(String(bidiOverride))Résumé\u{0000}\u{0007}\n次の行\t✅  "

        let result = try #require(YouTubeAskVisibleTextSanitizer.sanitizeAnswer(input))

        #expect(result.text == "مرحبًا Résumé\n次の行\t✅")
        #expect(!result.wasTruncated)
    }

    @Test("Removes CSI, OSC, and incomplete terminal sequences")
    func removesTerminalSequences() throws {
        let escape = try String(#require(UnicodeScalar(0x1B)))
        let bell = try String(#require(UnicodeScalar(0x07)))
        let input = "Start \(escape)[31mred\(escape)[0m middle "
            + "\(escape)]8;;https://placeholder.invalid\(bell)linked\(escape)]8;;\(bell) "
            + "end\(escape)[999"

        let result = try #require(YouTubeAskVisibleTextSanitizer.sanitizeAnswer(input))

        #expect(result.text == "Start red middle linked end")
    }

    @Test("Strips Markdown, autolink, HTTP, and www destinations")
    func stripsLinks() throws {
        let input = "Read [the label](https://placeholder.invalid/page), "
            + "<https://placeholder.invalid/auto>, https://placeholder.invalid/plain, "
            + "and www.placeholder.invalid/path"

        let result = try #require(YouTubeAskVisibleTextSanitizer.sanitizeAnswer(input))

        #expect(result.text.contains("the label"))
        #expect(!result.text.contains("placeholder.invalid"))
        #expect(result.text.components(separatedBy: "[link omitted]").count - 1 == 3)
    }

    @Test("Replaces high-entropy and UUID-shaped identifiers without removing normal prose")
    func stripsOpaqueIdentifiers() throws {
        let opaque = String(repeating: "Ab3_Cd4-Ef5.Gh6_", count: 4)
        let placeholderUUID = "00000000-0000-0000-0000-000000000000"
        let ordinary = String(repeating: "lowercaseword", count: 8)
        let input = "Before \(opaque) and \(placeholderUUID); keep \(ordinary)."

        let result = try #require(YouTubeAskVisibleTextSanitizer.sanitizeAnswer(input))

        #expect(!result.text.contains(opaque))
        #expect(!result.text.contains(placeholderUUID))
        #expect(result.text.components(separatedBy: "[opaque omitted]").count - 1 == 2)
        #expect(result.text.contains(ordinary))
    }

    @Test("Enforces chip-label limits without truncation")
    func chipLabelLimits() throws {
        let exact = String(repeating: "a", count: YouTubeAskLimits.maximumChipCharacters)
        let oversized = exact + "b"

        let accepted = try #require(YouTubeAskVisibleTextSanitizer.sanitizeChipLabel(exact))
        #expect(accepted.text.count == YouTubeAskLimits.maximumChipCharacters)
        #expect(!accepted.wasTruncated)
        #expect(YouTubeAskVisibleTextSanitizer.sanitizeChipLabel(oversized) == nil)
    }

    @Test("Truncates answers at a Character boundary and reports truncation")
    func answerLimits() throws {
        let exact = String(repeating: "✅", count: YouTubeAskLimits.maximumAnswerCharacters)
        let oversized = exact + "✅"

        let accepted = try #require(YouTubeAskVisibleTextSanitizer.sanitizeAnswer(exact))
        #expect(accepted.text.count == YouTubeAskLimits.maximumAnswerCharacters)
        #expect(!accepted.wasTruncated)

        let truncated = try #require(YouTubeAskVisibleTextSanitizer.sanitizeAnswer(oversized))
        #expect(truncated.text.count == YouTubeAskLimits.maximumAnswerCharacters)
        #expect(truncated.text.last == "✅")
        #expect(truncated.wasTruncated)
    }

    @Test("Returns nil when sanitization leaves no visible text")
    func rejectsEmptySanitizedText() throws {
        let escape = try String(#require(UnicodeScalar(0x1B)))
        #expect(YouTubeAskVisibleTextSanitizer.sanitizeAnswer("\u{0000}\u{0007}") == nil)
        #expect(YouTubeAskVisibleTextSanitizer.sanitizeChipLabel("\(escape)[31m") == nil)
    }
}
