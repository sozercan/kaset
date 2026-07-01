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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Label {
                Text(self.title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: self.systemImage)
                    .foregroundStyle(PackageResourceLookup.brandAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(self.selectionBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if self.isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
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
