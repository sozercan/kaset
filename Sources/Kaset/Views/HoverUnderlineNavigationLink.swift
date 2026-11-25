import SwiftUI

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
