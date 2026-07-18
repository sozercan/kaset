import SwiftUI

// MARK: - In-playlist search

@available(macOS 26.0, *)
extension PlaylistDetailView {
    /// Minimum loaded track count before the in-playlist search field appears, so short
    /// albums and playlists stay uncluttered.
    private static var searchFieldMinimumTrackCount: Int {
        8
    }

    /// Whether the in-playlist search field should be offered. Hidden for short, fully
    /// loaded lists where filtering adds clutter without value.
    func shouldShowSearchField(for detail: PlaylistDetail) -> Bool {
        // Once a query is active, keep the field visible even if the list later shrinks below
        // the threshold (eager load finishing, a track being removed) — otherwise the field
        // and its clear button would vanish while the list stays filtered, stranding the user.
        if !self.searchQuery.isEmpty {
            return true
        }
        return detail.tracks.count >= Self.searchFieldMinimumTrackCount || self.viewModel.hasMore
    }

    /// The collapsed search control that lives among the header action buttons: a
    /// magnifying-glass pill when idle, or a compact chip showing the active query plus a
    /// clear button. Tapping it expands the field via ``expandedSearchField``.
    var searchControl: some View {
        Group {
            if self.searchQuery.isEmpty {
                Button {
                    self.activateSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(String(localized: "Find in playlist"))
                .accessibilityLabel(String(localized: "Find in playlist"))
                .accessibilityIdentifier(AccessibilityID.PlaylistDetail.searchPill)
            } else {
                HStack(spacing: 6) {
                    Button {
                        self.activateSearch()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text(self.searchQuery)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(String(localized: "Edit search"))
                    .accessibilityIdentifier(AccessibilityID.PlaylistDetail.searchPill)

                    Button {
                        self.clearAndCollapseSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear search"))
                    .accessibilityLabel(String(localized: "Clear search"))
                    .accessibilityIdentifier(AccessibilityID.PlaylistDetail.clearSearchButton)
                }
            }
        }
    }

    /// The expanded, focused search field that temporarily takes over the header action row
    /// while typing. Auto-focuses on appear and folds back to ``searchControl`` when editing
    /// ends (blur, Return, or tapping a result).
    var expandedSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(localized: "Find in playlist"), text: self.$searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused(self.$searchFieldFocused)
                .onSubmit { self.searchFieldFocused = false }
                .accessibilityIdentifier(AccessibilityID.PlaylistDetail.searchField)

            Button {
                self.clearAndCollapseSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Clear search"))
            .accessibilityIdentifier(AccessibilityID.PlaylistDetail.clearSearchButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .compatGlass(in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { self.searchFieldFocused = true }
        .onChange(of: self.searchFieldFocused) { _, focused in
            guard !focused else { return }
            // Fold back to the pill/chip when editing ends, but defer one hop so a tap on the
            // in-field clear button finishes first — collapsing synchronously here would tear
            // the field down mid-click and drop that tap. Re-check focus in case it returned.
            Task { @MainActor in
                if !self.searchFieldFocused {
                    self.isSearchActive = false
                }
            }
        }
    }

    private func activateSearch() {
        self.isSearchActive = true
    }

    private func clearAndCollapseSearch() {
        // Defer the reset one hop so the tap that triggered it finishes on the ✕ first. Mutating
        // synchronously swaps the chip/field for the pill *under the cursor*, and the click's
        // completion then lands on that pill — re-activating search and reopening an empty field.
        Task { @MainActor in
            self.searchQuery = ""
            self.searchFieldFocused = false
            self.isSearchActive = false
        }
    }

    /// Plays exactly the given tracks (the current search matches) as the queue, starting at
    /// `index` within them. Unlike ``playTrackInQueue(tracks:startingAt:fallbackArtist:fallbackAlbum:)``
    /// it does NOT grow the queue to the full playlist — the queue is only the results.
    func playSearchResults(
        _ tracks: [Song], startingAt index: Int, fallbackArtist: String? = nil,
        fallbackAlbum: Album? = nil
    ) {
        guard tracks.indices.contains(index), tracks[index].isPlayable else { return }

        let playableIndex = tracks[...index].filter(\.isPlayable).count - 1
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        guard cleanedTracks.indices.contains(playableIndex) else { return }
        Task { @MainActor in
            await self.playerService.playQueue(cleanedTracks, startingAt: playableIndex)
        }
    }

    /// The playlist's tracks, filtered by `searchQuery`. Each rendered row carries its
    /// original playlist index, so playing a match starts the queue at that track's real
    /// position — identical to the unfiltered list.
    func tracksView(
        _ tracks: [Song], isAlbum: Bool, author: String?, fallbackAlbum: Album? = nil
    ) -> some View {
        let rows = PlaylistTrackFilter.filter(tracks, query: self.searchQuery)
        return LazyVStack(spacing: 0) {
            // Show "No Results" only for an active query that is done loading: a genuinely
            // empty playlist (no query) renders nothing, and while the playlist is still
            // paging in — an eager search load may not have reached the matching tail yet —
            // the pagination spinner below signals progress instead of a premature empty state.
            if rows.isEmpty, !self.searchQuery.isEmpty, !self.viewModel.hasMore {
                self.noSearchResultsView
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                // `index: row.index` shows the track's real playlist number; `playFilteredRow`
                // resolves the queue source (the search results while filtering, else the full
                // playlist from the original index).
                self.trackRow(
                    row.track, index: row.index, isAlbum: isAlbum, author: author,
                    onPlay: {
                        self.playFilteredRow(
                            at: position, in: rows, fullTracks: tracks,
                            fallbackArtist: author, fallbackAlbum: fallbackAlbum
                        )
                    }
                )
                .onAppear {
                    // Scroll-based pagination only applies to the unfiltered list; a search
                    // eagerly loads the whole playlist, so the last *visible* filtered row is
                    // not a meaningful pagination trigger.
                    if self.searchQuery.isEmpty, row.index >= tracks.count - 3, self.viewModel.hasMore {
                        Task { await self.viewModel.loadMore() }
                    }
                }

                if position < rows.count - 1 {
                    Divider()
                        // For albums: 28 (index) + 12 (spacing)
                        // For playlists: 28 (index) + 12 (spacing) + 40 (thumbnail) + 16 (spacing)
                        .padding(.leading, isAlbum ? 40 : 96)
                }
            }

            // Loading indicator for pagination
            if self.viewModel.loadingState == .loadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .padding()
                    Spacer()
                }
            }
        }
    }

    private var noSearchResultsView: some View {
        ContentUnavailableView.search(text: self.searchQuery)
            .accessibilityIdentifier(AccessibilityID.PlaylistDetail.searchEmptyState)
            .padding(.top, 48)
    }
}
