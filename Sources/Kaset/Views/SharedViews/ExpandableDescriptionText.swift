import SwiftUI

/// Readable progressive disclosure for API-provided prose descriptions.
struct ExpandableDescriptionText: View {
    private static let collapsedLineLimit = 3
    private static let readableWidth: CGFloat = 720
    private static let popoverWidth: CGFloat = 560
    private static let popoverHeight: CGFloat = 360
    private static let truncationTolerance: CGFloat = 0.5

    private let text: String

    @State private var showsFullDescription = false
    @State private var previewHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    init(_ text: String) {
        self.text = text
    }

    private var isTruncated: Bool {
        self.fullHeight > self.previewHeight + Self.truncationTolerance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            self.descriptionText
                .lineLimit(Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    self.previewHeight = $0
                }
                .background {
                    self.descriptionText
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            self.fullHeight = $0
                        }
                }

            if self.isTruncated {
                Button(String(localized: "More")) {
                    self.showsFullDescription = true
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
                .popover(isPresented: self.$showsFullDescription) {
                    self.fullDescriptionPopover
                }
            }
        }
        .frame(maxWidth: Self.readableWidth, alignment: .leading)
    }

    private var descriptionText: some View {
        Text(self.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
    }

    private var fullDescriptionPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                self.descriptionText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()

                Button(String(localized: "Done")) {
                    self.showsFullDescription = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
    }
}
