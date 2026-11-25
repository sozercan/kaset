import SwiftUI

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
                    .fontWeight(self.isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: self.systemImage)
                    .foregroundStyle(PackageResourceLookup.brandAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(self.selectionBackground)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if self.isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
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
