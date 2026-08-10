import SwiftUI

// MARK: - Sort & Search UI

@available(macOS 26.0, *)
extension PlaylistDetailView {
    /// Whether a non-empty search query is currently active.
    var hasActiveSearch: Bool {
        !self.viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Toolbar menu that chooses the client-side sort order for the track list.
    var sortMenu: some View {
        Menu {
            ForEach(PlaylistSortKey.allCases) { key in
                Button {
                    self.selectSortKey(key)
                } label: {
                    self.sortMenuLabel(for: key)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help(String(localized: "Sort songs"))
    }

    @ViewBuilder
    private func sortMenuLabel(for key: PlaylistSortKey) -> some View {
        if self.viewModel.sortOrder.key == key, key != .original {
            Label(
                key.displayName,
                systemImage: self.viewModel.sortOrder.ascending ? "chevron.up" : "chevron.down"
            )
        } else if self.viewModel.sortOrder.key == key {
            Label(key.displayName, systemImage: "checkmark")
        } else {
            Text(key.displayName)
        }
    }

    /// Selecting the active key toggles direction; a new key sorts ascending;
    /// `.original` returns to server order.
    func selectSortKey(_ key: PlaylistSortKey) {
        if key == .original {
            self.viewModel.setSortOrder(.default)
            return
        }
        if self.viewModel.sortOrder.key == key {
            self.viewModel.setSortOrder(
                PlaylistSortOrder(key: key, ascending: !self.viewModel.sortOrder.ascending)
            )
        } else {
            self.viewModel.setSortOrder(PlaylistSortOrder(key: key, ascending: true))
        }
    }

    /// Inline search field that filters the track list locally.
    @ViewBuilder
    var searchField: some View {
        let query = Binding(
            get: { self.viewModel.searchQuery },
            set: { self.viewModel.setSearchQuery($0) }
        )
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search in Playlist"), text: query)
                .textFieldStyle(.plain)
            if !self.viewModel.searchQuery.isEmpty {
                Button {
                    self.viewModel.setSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .compatGlass(in: .capsule)
    }
}
