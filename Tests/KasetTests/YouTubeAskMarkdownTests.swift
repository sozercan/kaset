import Foundation
import Testing
@testable import Kaset

@Suite("YouTube Ask Markdown")
struct YouTubeAskMarkdownTests {
    @Test("Parses paragraphs, headings, lists, quotes, and code blocks")
    func parsesBlocks() {
        let markdown = """
        Intro paragraph.

        **Main Headlines:**
        * **First:** Details
        * Second

        1. One
        2. Two

        > Check this carefully.

        ```swift
        let value = 1
        ```
        """

        #expect(YouTubeAskMarkdown.blocks(from: markdown) == [
            .paragraph("Intro paragraph."),
            .paragraph("**Main Headlines:**"),
            .unorderedList(["**First:** Details", "Second"]),
            .orderedList([
                .init(number: 1, text: "One"),
                .init(number: 2, text: "Two"),
            ]),
            .blockQuote("Check this carefully."),
            .codeBlock("let value = 1"),
        ])
    }

    @Test("Preserves explicit ordered-list markers visually and for accessibility")
    func preservesOrderedListMarkers() {
        let markdown = """
        5. Fifth
        7. Seventh
        """

        #expect(YouTubeAskMarkdown.blocks(from: markdown) == [
            .orderedList([
                .init(number: 5, text: "Fifth"),
                .init(number: 7, text: "Seventh"),
            ]),
        ])
        #expect(YouTubeAskMarkdown.plainText(from: markdown) == "5. Fifth\n7. Seventh")
    }

    @Test("Renders inline emphasis while removing link attributes")
    func safeInlineMarkdown() {
        let attributed = YouTubeAskMarkdown.inlineAttributedString(
            "**Bold**, *italic*, `code`, [first](/relative/one), and [second](/relative/two)"
        )

        #expect(String(attributed.characters) == "Bold, italic, code, first, and second")
        #expect(attributed.runs.allSatisfy { $0.link == nil })
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.emphasized) == true
        })
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        })
    }

    @Test("Accessibility text omits Markdown syntax")
    func plainAccessibilityText() {
        let markdown = """
        **Summary**

        * **First:** Details
        * Second
        """

        #expect(YouTubeAskMarkdown.plainText(from: markdown) == "Summary\nFirst: Details. Second")
    }
}
