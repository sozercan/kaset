import SwiftUI

// MARK: - HoverUnderlineNavigationLink

/// A navigation link that underlines its label on hover.
///
/// Used for artist names and other inline navigation targets in track rows and headers.
struct HoverUnderlineNavigationLink<Value: Hashable>: View {
    let value: Value
    let title: String
    var font: Font = .subheadline
    var foregroundStyle: Color = .secondary

    @State private var isHovering = false

    var body: some View {
        NavigationLink(value: self.value) {
            Text(self.title)
                .font(self.font)
                .foregroundStyle(self.foregroundStyle)
                .underline(self.isHovering)
                .lineLimit(1)
                .padding(.vertical, 2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering in
            self.isHovering = hovering
        }
    }
}
