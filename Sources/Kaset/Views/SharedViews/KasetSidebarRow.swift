import SwiftUI

// MARK: - KasetSidebarRow

/// A stable Apple-Music-style sidebar row.
///
/// SwiftUI's source-list `NavigationLink` chrome changes when the sidebar list
/// becomes the active control: selected rows switch to the system accent fill
/// and symbols become selected-text colored. Kaset drives detail content from
/// explicit selection state, so use a plain button row with our own selected
/// background and brand-accent symbol instead of relying on `NavigationLink`'s
/// active/inactive source-list styling.
struct KasetSidebarRow: View {
    let title: String
    let systemImage: String
    /// Optional artwork shown instead of the symbol (e.g. playlist covers).
    var thumbnailURL: URL?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            Label {
                Text(self.title)
                    .lineLimit(1)
                    .fontWeight(self.isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
            } icon: {
                if let thumbnailURL {
                    self.thumbnailView(url: thumbnailURL)
                } else {
                    Image(systemName: self.systemImage)
                        .foregroundStyle(PackageResourceLookup.brandAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHovering = hovering
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(self.rowBackground)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    /// Small rounded-rect artwork matching the app's small-artwork corner radius.
    private func thumbnailView(url: URL) -> some View {
        CachedAsyncImage(url: url, targetSize: CGSize(width: 32, height: 32)) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: self.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 16, height: 16)
        .clipShape(.rect(cornerRadius: 6))
    }

    @ViewBuilder private var rowBackground: some View {
        if self.isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        } else if self.isHovering {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
    }
}

#Preview {
    List {
        KasetSidebarRow(
            title: "Home",
            systemImage: "house",
            isSelected: true,
            action: {}
        )
        KasetSidebarRow(
            title: "Search",
            systemImage: "magnifyingglass",
            isSelected: false,
            action: {}
        )
    }
    .listStyle(.sidebar)
    .frame(width: 220)
}
