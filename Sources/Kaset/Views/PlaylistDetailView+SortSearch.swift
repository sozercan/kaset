import SwiftUI

// MARK: - Sort & Search UI

@available(macOS 26.0, *)
extension PlaylistDetailView {
    /// Whether a non-empty search query is currently active.
    var hasActiveSearch: Bool {
        !self.viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Two-way binding over the view model's search query, for `.searchable`.
    var searchBinding: Binding<String> {
        Binding(
            get: { self.viewModel.searchQuery },
            set: { self.viewModel.setSearchQuery($0) }
        )
    }

    /// Progress shown while a sort or search is active and pages are still arriving. It
    /// sits above the list because each page re-sorts the rows under the user, and a
    /// bottom-of-list spinner is unreachable exactly when they need to know why.
    @ViewBuilder
    var drainProgressBanner: some View {
        let loaded = self.viewModel.playlistDetail?.tracks.count ?? 0
        let total = self.viewModel.playlistDetail?.trackCount

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "Loading all songs…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let total, total > loaded {
                Text(verbatim: "\(loaded) / \(total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .compatGlass(in: .capsule)
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
            self.sortMenuButtonLabel
        }
        .labelStyle(.titleAndIcon)
        .help(String(localized: "Sort songs"))
    }

    /// The collapsed toolbar label. It names the active key and direction, so the order is
    /// readable without opening the menu.
    @ViewBuilder
    private var sortMenuButtonLabel: some View {
        let order = self.viewModel.sortOrder
        if order.key == .original {
            Image(systemName: "arrow.up.arrow.down")
        } else {
            Label(
                order.key.displayName,
                systemImage: order.ascending ? "arrow.up" : "arrow.down"
            )
        }
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
}
