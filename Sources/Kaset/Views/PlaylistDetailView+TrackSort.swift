import SwiftUI

@available(macOS 26.0, *)
extension PlaylistDetailView {
    @ViewBuilder
    func trackSortMenu(_ detail: PlaylistDetail) -> some View {
        if detail.tracks.count >= 2 {
            HStack {
                Spacer()

                Menu {
                    ForEach(PlaylistTrackSortOption.allCases, id: \.self) { option in
                        Button {
                            self.viewModel.selectSort(option)
                        } label: {
                            HStack {
                                Text(self.sortOptionTitle(option))
                                if self.viewModel.sortOption == option {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                    if option != .custom {
                                        Image(systemName: self.viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    self.trackSortMenuLabel
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help(String(localized: "Sort tracks"))
                .accessibilityLabel(String(localized: "Sort tracks"))
            }
        }
    }

    private var trackSortMenuLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down")
            if self.viewModel.sortOption != .custom {
                Text(self.sortOptionTitle(self.viewModel.sortOption))
            }
        }
    }

    private func sortOptionTitle(_ option: PlaylistTrackSortOption) -> String {
        switch option {
        case .custom:
            String(localized: "Custom order")
        case .title:
            String(localized: "Title")
        case .artist:
            String(localized: "Artist")
        case .duration:
            String(localized: "Duration")
        }
    }
}
