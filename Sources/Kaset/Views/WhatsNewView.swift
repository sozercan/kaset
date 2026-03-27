import AppKit
import SwiftUI

// MARK: - WhatsNewView

/// Sheet view that showcases new features for the current app version.
/// Displays either structured feature rows (static fallback) or markdown release notes (from GitHub).
@available(macOS 26.0, *)
struct WhatsNewView: View {
    private enum Layout {
        static let sheetWidth: CGFloat = 640
        static let sheetHeight: CGFloat = 620
        static let contentMinHeight: CGFloat = 280
    }

    @Environment(\.colorScheme) private var colorScheme

    let whatsNew: WhatsNew
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            self.headerView
            self.contentCard
                .frame(maxHeight: .infinity, alignment: .top)
            self.footerView
        }
        .padding(24)
        .frame(width: Self.Layout.sheetWidth)
        .frame(idealHeight: Self.Layout.sheetHeight, maxHeight: Self.Layout.sheetHeight, alignment: .top)
        .background {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(self.colorScheme == .dark ? 0.16 : 0.08),
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var headerView: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.accentColor.opacity(self.colorScheme == .dark ? 0.18 : 0.10))
                    .frame(width: 88, height: 88)

                CassetteIcon(size: 52)
                    .foregroundStyle(.tint)
            }

            Text("\(String(localized: "Version")) \(self.whatsNew.version.description)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    private var contentCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: self.contentSectionIcon)
                    .font(.subheadline.weight(.semibold))

                Text(self.contentSectionTitle)
                    .font(.subheadline.weight(.semibold))

                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .opacity(0.5)

            self.contentContainer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(self.colorScheme == .dark ? 0.88 : 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(self.colorScheme == .dark ? 0.08 : 0.28))
        }
    }

    @ViewBuilder
    private var contentContainer: some View {
        if self.whatsNew.releaseNotes != nil {
            ScrollView {
                self.contentView
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            self.contentView
                .padding(24)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.Layout.contentMinHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let releaseNotes = self.whatsNew.releaseNotes {
            MarkdownContentView(markdown: releaseNotes)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(self.whatsNew.features, id: \.self) { feature in
                    WhatsNewFeatureRow(feature: feature)
                }
            }
        }
    }

    private var footerView: some View {
        HStack(spacing: 16) {
            if let url = self.whatsNew.learnMoreURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Learn more", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            Spacer(minLength: 12)

            Button {
                self.onDismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .glassEffect()
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 4)
    }

    private var contentSectionTitle: String {
        self.whatsNew.releaseNotes == nil ? String(localized: "Highlights") : String(localized: "Release Notes")
    }

    private var contentSectionIcon: String {
        self.whatsNew.releaseNotes == nil ? "sparkles.rectangle.stack.fill" : "text.document"
    }
}

// MARK: - MarkdownContentView

/// Renders GitHub-flavored markdown into native SwiftUI views.
@available(macOS 26.0, *)
private struct MarkdownContentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(self.blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parses markdown into an array of block-level views.
    private var blocks: [AnyView] {
        let lines = Self.normalizedLines(from: self.markdown)
        var result: [AnyView] = []
        var i = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else {
                return
            }

            result.append(AnyView(Self.paragraph(Self.inlineMarkdown(paragraphLines.joined(separator: " ")))))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                // Skip blank lines — VStack spacing handles gaps between blocks
                flushParagraph()
                i += 1
            } else if trimmed.hasPrefix("<!--") {
                flushParagraph()
                repeat {
                    i += 1
                } while i < lines.count && !lines[i - 1].contains("-->")
            } else if Self.isSpacerLine(trimmed) {
                flushParagraph()
                i += 1
            } else if Self.isThematicBreak(trimmed) {
                flushParagraph()
                i += 1
            } else if trimmed.hasPrefix("### ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(4))
                result.append(AnyView(Self.heading(Self.inlineMarkdown(text), font: .headline, topPadding: 2)))
                i += 1
            } else if trimmed.hasPrefix("## ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(3))
                result.append(AnyView(Self.heading(Self.inlineMarkdown(text), font: .title3.weight(.bold), topPadding: 6)))
                i += 1
            } else if trimmed.hasPrefix("# ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2))
                result.append(AnyView(Self.heading(Self.inlineMarkdown(text), font: .title2.weight(.bold), topPadding: 10)))
                i += 1
            } else if let firstItem = Self.listItemText(from: trimmed) {
                flushParagraph()
                // Collect consecutive list items
                var items = [firstItem]
                i += 1
                while i < lines.count {
                    let listLine = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let item = Self.listItemText(from: listLine) else {
                        break
                    }

                    items.append(item)
                    i += 1
                }
                result.append(AnyView(Self.list(items)))
            } else if trimmed.hasPrefix("```") {
                flushParagraph()
                // Code block — collect until closing ```
                i += 1
                var codeLines: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                let code = codeLines.joined(separator: "\n")
                result.append(AnyView(Self.codeBlock(code)))
            } else {
                // Merge wrapped markdown lines into a single paragraph block.
                paragraphLines.append(trimmed)
                i += 1
            }
        }

        flushParagraph()
        return result
    }

    /// Parses inline markdown (bold, italic, code, links) into an AttributedString.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        // Use Foundation's markdown parser for inline formatting
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }

    private static func normalizedLines(from markdown: String) -> [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func listItemText(from line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }

        guard let markerRange = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else {
            return nil
        }

        return String(line[markerRange.upperBound...])
    }

    private static func isSpacerLine(_ line: String) -> Bool {
        switch line.lowercased() {
        case "<br>", "<br/>", "<br />":
            true
        default:
            false
        }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first else {
            return false
        }

        guard first == "-" || first == "*" || first == "_" else {
            return false
        }

        return stripped.allSatisfy { $0 == first }
    }

    private static func heading(_ text: AttributedString, font: Font, topPadding: CGFloat) -> some View {
        Text(text)
            .font(font)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func paragraph(_ text: AttributedString) -> some View {
        Text(text)
            .font(.body)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func list(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .padding(.top, 8)

                    Text(self.inlineMarkdown(item))
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize()
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.45))
        }
    }
}

// MARK: - WhatsNewFeatureRow

/// A row displaying a single feature with icon, title, and subtitle.
@available(macOS 26.0, *)
private struct WhatsNewFeatureRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let feature: WhatsNew.Feature

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(self.colorScheme == .dark ? 0.18 : 0.10))
                    .frame(width: 52, height: 52)

                Image(systemName: self.feature.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(self.feature.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(self.feature.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(self.colorScheme == .dark ? 0.72 : 0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(self.colorScheme == .dark ? 0.05 : 0.18))
        }
    }
}
