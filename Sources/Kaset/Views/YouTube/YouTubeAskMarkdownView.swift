import Foundation
import SwiftUI

// MARK: - YouTubeAskMarkdown

enum YouTubeAskMarkdown {
    struct OrderedListItem: Equatable {
        let number: Int
        let text: String
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedList([String])
        case orderedList([OrderedListItem])
        case blockQuote(String)
        case codeBlock(String)
        case thematicBreak
    }

    static func blocks(from markdown: String) -> [Block] {
        let lines = self.normalizedLines(from: markdown)
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
                {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = self.heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if self.isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if let item = self.unorderedListItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = self.unorderedListItem(
                          from: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                      )
                {
                    items.append(next)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = self.orderedListItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = self.orderedListItem(
                          from: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                      )
                {
                    items.append(next)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                var quotedLines = [String(trimmed.dropFirst(2))]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard next.hasPrefix("> ") else { break }
                    quotedLines.append(String(next.dropFirst(2)))
                    index += 1
                }
                blocks.append(.blockQuote(quotedLines.joined(separator: " ")))
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    static func inlineAttributedString(_ markdown: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)

        attributed.link = nil
        return attributed
    }

    static let truncationIndicator = "…"

    static func plainText(from markdown: String, wasTruncated: Bool = false) -> String {
        let plainText = self.blocks(from: markdown).map { block in
            switch block {
            case let .heading(_, text), let .paragraph(text), let .blockQuote(text):
                String(self.inlineAttributedString(text).characters)
            case let .unorderedList(items):
                items.map { String(self.inlineAttributedString($0).characters) }
                    .joined(separator: ". ")
            case let .orderedList(items):
                items.map { item in
                    "\(item.number). \(String(self.inlineAttributedString(item.text).characters))"
                }
                .joined(separator: "\n")
            case let .codeBlock(code):
                code
            case .thematicBreak:
                ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        return wasTruncated ? plainText + self.truncationIndicator : plainText
    }

    private static func normalizedLines(from markdown: String) -> [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1 ... 6).contains(prefix.count),
              line.dropFirst(prefix.count).first == " "
        else {
            return nil
        }
        let text = String(line.dropFirst(prefix.count + 1))
        return text.isEmpty ? nil : (prefix.count, text)
    }

    private static func unorderedListItem(from line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") else {
            return nil
        }
        let text = String(line.dropFirst(2))
        return text.isEmpty ? nil : text
    }

    private static func orderedListItem(from line: String) -> OrderedListItem? {
        guard let marker = line.range(of: #"^\d+\.\s+"#, options: .regularExpression),
              let number = Int(line[..<marker.upperBound].prefix(while: { $0.isNumber }))
        else {
            return nil
        }
        let text = String(line[marker.upperBound...])
        return text.isEmpty ? nil : OrderedListItem(number: number, text: text)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first,
              first == "-" || first == "*" || first == "_"
        else {
            return false
        }
        return stripped.allSatisfy { $0 == first }
    }
}

// MARK: - YouTubeAskMarkdownView

struct YouTubeAskMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(YouTubeAskMarkdown.blocks(from: self.markdown).enumerated()), id: \.offset) { _, block in
                self.blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: YouTubeAskMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(YouTubeAskMarkdown.inlineAttributedString(text))
                .font(self.headingFont(level: level))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(text):
            self.markdownText(text)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•")
                            .foregroundStyle(.secondary)
                        self.markdownText(item)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(item.number).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        self.markdownText(item.text)
                    }
                }
            }

        case let .blockQuote(text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                self.markdownText(text)
                    .foregroundStyle(.secondary)
            }

        case let .codeBlock(code):
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

        case .thematicBreak:
            Divider()
        }
    }

    private func markdownText(_ text: String) -> some View {
        Text(YouTubeAskMarkdown.inlineAttributedString(text))
            .font(.callout)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            .title3.weight(.bold)
        case 2:
            .headline.weight(.bold)
        default:
            .callout.weight(.semibold)
        }
    }
}
