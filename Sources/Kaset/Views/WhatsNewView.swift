import AppKit
import SwiftUI

// MARK: - WhatsNewView

/// Sheet view that showcases new features for the current app version.
/// Displays either structured feature rows (static fallback) or markdown release notes (from GitHub).
@available(macOS 26.0, *)
struct WhatsNewView: View {
    let whatsNew: WhatsNew
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 40)

            // Title
            Text(self.whatsNew.title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
                .frame(height: 24)

            // Content: markdown release notes or structured feature rows
            ScrollView {
                if let releaseNotes = self.whatsNew.releaseNotes {
                    MarkdownContentView(markdown: releaseNotes)
                        .padding(.horizontal, 36)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(self.whatsNew.features, id: \.self) { feature in
                            WhatsNewFeatureRow(feature: feature)
                        }
                    }
                    .padding(.horizontal, 48)
                }
            }

            Spacer()
                .frame(height: 16)

            // Footer actions
            VStack(spacing: 12) {
                // Learn more link
                if let url = self.whatsNew.learnMoreURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("Learn more")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }

                // Continue button
                Button {
                    self.onDismiss()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .glassEffect()
                .keyboardShortcut(.defaultAction)
            }

            Spacer()
                .frame(height: 32)
        }
        .frame(width: 520)
        .frame(minHeight: 520)
    }
}

// MARK: - MarkdownContentView

/// Renders GitHub-flavored markdown into native SwiftUI views.
@available(macOS 26.0, *)
private struct MarkdownContentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(self.blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parses markdown into an array of block-level views.
    private var blocks: [AnyView] {
        let lines = self.markdown.components(separatedBy: "\n")
        var result: [AnyView] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Blank line — small spacer
                result.append(AnyView(Spacer().frame(height: 4)))
                i += 1
            } else if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                result.append(AnyView(
                    Text(Self.inlineMarkdown(text))
                        .font(.headline)
                        .padding(.top, 4)
                ))
                i += 1
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                result.append(AnyView(
                    Text(Self.inlineMarkdown(text))
                        .font(.title3.bold())
                        .padding(.top, 6)
                ))
                i += 1
            } else if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                result.append(AnyView(
                    Text(Self.inlineMarkdown(text))
                        .font(.title2.bold())
                        .padding(.top, 8)
                ))
                i += 1
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // Collect consecutive list items
                var items: [String] = []
                while i < lines.count {
                    let listLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if listLine.hasPrefix("- ") {
                        items.append(String(listLine.dropFirst(2)))
                        i += 1
                    } else if listLine.hasPrefix("* ") {
                        items.append(String(listLine.dropFirst(2)))
                        i += 1
                    } else {
                        break
                    }
                }
                result.append(AnyView(
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text(Self.inlineMarkdown(item))
                            }
                        }
                    }
                ))
            } else if trimmed.hasPrefix("```") {
                // Code block — collect until closing ```
                i += 1
                var codeLines: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                let code = codeLines.joined(separator: "\n")
                result.append(AnyView(
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                ))
            } else {
                // Regular paragraph
                result.append(AnyView(
                    Text(Self.inlineMarkdown(trimmed))
                ))
                i += 1
            }
        }

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
}

// MARK: - WhatsNewFeatureRow

/// A row displaying a single feature with icon, title, and subtitle.
@available(macOS 26.0, *)
private struct WhatsNewFeatureRow: View {
    let feature: WhatsNew.Feature

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: self.feature.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.feature.title)
                    .font(.headline)

                Text(self.feature.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
