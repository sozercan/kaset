import Foundation

// MARK: - YouTubeFeedbackDismissal

/// Cards removed from a feed after recommendation feedback, kept so the
/// dismissal can be undone and the cards restored to their places.
struct YouTubeFeedbackDismissal: Identifiable {
    /// A removed card and the index it had in its list. The index is only a
    /// fallback: cards go back by their learned order among their neighbors.
    struct Removal {
        let index: Int
        let video: YouTubeVideo
    }

    /// A rail the dismissal emptied and removed, with its cards as they were
    /// before the dismissal.
    struct RemovedSection {
        let section: YouTubeHomeSection
    }

    let id = UUID()
    let action: YouTubeFeedbackAction
    /// The video the feedback was sent for.
    let videoID: String
    /// The channel hidden by "Don't recommend channel", if any.
    let channelID: String?
    /// Removed cards from the flat grid.
    let gridRemovals: [Removal]
    /// Removed cards per rail, keyed by section ID.
    let sectionRemovals: [String: [Removal]]
    /// Rails the dismissal emptied, restored on undo.
    let removedSections: [RemovedSection]

    /// Whether YouTube offered a way to reverse this feedback.
    var canUndo: Bool {
        self.action.undoToken != nil
    }
}

// MARK: - YouTubeFeedbackDismissals

/// Videos and channels dismissed through recommendation feedback this session,
/// plus the bookkeeping that hides their Home cards and restores them on undo.
///
/// Continue Watching is the user's own history, not a recommendation, so it
/// is never filtered.
struct YouTubeFeedbackDismissals {
    /// How many accepted dismissals cover each video and channel. An ID stops
    /// filtering only when every dismissal that covers it has been undone,
    /// because each undo token reverses only its own feedback.
    private var videoCounts: [String: Int] = [:]
    private var channelCounts: [String: Int] = [:]

    /// Cards an undo could not restore yet because another dismissal still
    /// covered them, or because their rail was gone. Later undos restore them
    /// once nothing covers them anymore.
    private var heldGridRemovals: [YouTubeFeedbackDismissal.Removal] = []
    private var heldSectionRemovals: [String: [YouTubeFeedbackDismissal.Removal]] = [:]

    /// Every recommendation rail seen on dismiss and undo, so any undo can
    /// bring back a rail that holds cards it restores, whichever dismissal
    /// removed the rail.
    private var knownRails: [String: YouTubeHomeSection] = [:]

    /// Stable order keys, learned from every list seen on dismiss and undo:
    /// one per rail, and one per card in the grid and in each rail. Restored
    /// rails and cards go back between the same neighbors as before, even when
    /// other dismissals and undos changed the lists in between.
    private var railOrder: [String: Double] = [:]
    private var gridCardOrder: [String: Double] = [:]
    private var railCardOrder: [String: [String: Double]] = [:]

    private var isEmpty: Bool {
        self.videoCounts.isEmpty && self.channelCounts.isEmpty
    }

    func isDismissed(_ video: YouTubeVideo) -> Bool {
        if self.videoCounts[video.videoId] != nil {
            return true
        }
        guard let channelID = video.channelId else { return false }
        return self.channelCounts[channelID] != nil
    }

    func filtered(_ videos: [YouTubeVideo]) -> [YouTubeVideo] {
        guard !self.isEmpty else { return videos }
        return videos.filter { !self.isDismissed($0) }
    }

    /// Filters dismissed videos out of recommendation rails and drops rails
    /// left empty.
    func filtered(_ sections: [YouTubeHomeSection]) -> [YouTubeHomeSection] {
        guard !self.isEmpty else { return sections }
        return sections.compactMap { section in
            guard section.kind != .continueWatching else { return section }
            let remaining = self.filtered(section.videos)
            if remaining.count == section.videos.count {
                return section
            }
            return remaining.isEmpty ? nil : section.replacingVideos(remaining)
        }
    }

    /// Records feedback YouTube accepted for `video` and removes the affected
    /// cards: the video itself, or every card from its channel.
    mutating func dismiss(
        _ action: YouTubeFeedbackAction,
        for video: YouTubeVideo,
        videos: inout [YouTubeVideo],
        sections: inout [YouTubeHomeSection]
    ) -> YouTubeFeedbackDismissal {
        self.learnLayout(videos: videos, sections: sections)
        let channelID = action.kind == .dontRecommendChannel ? video.channelId : nil
        Self.add(video.videoId, to: &self.videoCounts)
        if let channelID {
            Self.add(channelID, to: &self.channelCounts)
        }

        let matches: (YouTubeVideo) -> Bool = { candidate in
            candidate.videoId == video.videoId
                || (channelID != nil && candidate.channelId == channelID)
        }

        let gridRemovals = Self.removals(in: videos, matching: matches)
        var sectionRemovals: [String: [YouTubeFeedbackDismissal.Removal]] = [:]
        for section in sections where section.kind != .continueWatching {
            let removals = Self.removals(in: section.videos, matching: matches)
            if !removals.isEmpty {
                sectionRemovals[section.id] = removals
            }
        }

        videos.removeAll(where: matches)
        var remainingSections: [YouTubeHomeSection] = []
        var removedSections: [YouTubeFeedbackDismissal.RemovedSection] = []
        for section in sections {
            guard sectionRemovals[section.id] != nil else {
                remainingSections.append(section)
                continue
            }
            let remaining = section.videos.filter { !matches($0) }
            if remaining.isEmpty {
                removedSections.append(.init(section: section))
            } else {
                remainingSections.append(section.replacingVideos(remaining))
            }
        }
        sections = remainingSections

        return YouTubeFeedbackDismissal(
            action: action,
            videoID: video.videoId,
            channelID: channelID,
            gridRemovals: gridRemovals,
            sectionRemovals: sectionRemovals,
            removedSections: removedSections
        )
    }

    /// Forgets an undone dismissal and puts its cards, and any rails it
    /// emptied, back where they were. Cards that another dismissal still
    /// covers are held and come back when that dismissal is undone too.
    mutating func undo(
        _ dismissal: YouTubeFeedbackDismissal,
        videos: inout [YouTubeVideo],
        sections: inout [YouTubeHomeSection]
    ) {
        Self.remove(dismissal.videoID, from: &self.videoCounts)
        if let channelID = dismissal.channelID {
            Self.remove(channelID, from: &self.channelCounts)
        }
        // Gives cards and rails that loaded since the dismissal a place
        // among the remembered ones.
        self.learnLayout(videos: videos, sections: sections)

        // This dismissal's cards plus everything earlier undos had to hold.
        let gridCandidates = Self.uniqued(self.heldGridRemovals + dismissal.gridRemovals)
        self.heldGridRemovals = gridCandidates.filter { self.isDismissed($0.video) }
        videos = Self.reinserting(
            gridCandidates.filter { !self.isDismissed($0.video) },
            into: videos,
            order: self.gridCardOrder
        )

        // Rail cards waiting to come back, keyed by rail. A rail this
        // dismissal emptied contributes all its cards.
        var pending = self.heldSectionRemovals.merging(dismissal.sectionRemovals) { $0 + $1 }
        for removed in dismissal.removedSections {
            let snapshot = removed.section.videos.enumerated()
                .map { YouTubeFeedbackDismissal.Removal(index: $0.offset, video: $0.element) }
            pending[removed.section.id, default: []] += snapshot
        }

        for railID in pending.keys.sorted() {
            let candidates = Self.uniqued(pending[railID] ?? [])
            let restorable = candidates.filter { !self.isDismissed($0.video) }
            pending[railID] = candidates.filter { self.isDismissed($0.video) }
            guard !restorable.isEmpty else { continue }

            let order = self.railCardOrder[railID] ?? [:]
            if let index = sections.firstIndex(where: { $0.id == railID }) {
                sections[index] = sections[index]
                    .replacingVideos(Self.reinserting(restorable, into: sections[index].videos, order: order))
            } else if let rail = self.knownRails[railID] {
                sections.insert(
                    rail.replacingVideos(Self.reinserting(restorable, into: [], order: order)),
                    at: self.insertionIndex(forRail: railID, in: sections)
                )
            } else {
                pending[railID] = candidates
            }
        }
        self.heldSectionRemovals = pending.filter { !$0.value.isEmpty }
    }

    /// Learns the order of every rail and card in these lists, and each
    /// recommendation rail's title and kind.
    private mutating func learnLayout(videos: [YouTubeVideo], sections: [YouTubeHomeSection]) {
        Self.learnOrder(of: sections.map(\.id), into: &self.railOrder)
        Self.learnOrder(of: videos.map(\.videoId), into: &self.gridCardOrder)
        for section in sections where section.kind != .continueWatching {
            self.knownRails[section.id] = section
            Self.learnOrder(of: section.videos.map(\.videoId), into: &self.railCardOrder[section.id, default: [:]])
        }
    }

    /// Gives every ID not seen before an order key between its known
    /// neighbors in this list. Keys of removed items count too, so a new item
    /// never takes a removed item's place: one appended at the end goes after
    /// every known item, and one inserted between neighbors goes before the
    /// next known key.
    private static func learnOrder(of ids: [String], into order: inout [String: Double]) {
        for (index, id) in ids.enumerated() where order[id] == nil {
            let known = order
            let previousKey = ids[..<index].reversed().first { known[$0] != nil }.flatMap { known[$0] }
            let nextKey = ids[(index + 1)...].first { known[$0] != nil }.flatMap { known[$0] }
            let knownKeys = known.values
            order[id] = switch (previousKey, nextKey) {
            case let (previous?, next?):
                (previous + (knownKeys.filter { $0 > previous }.min() ?? next)) / 2
            case (_?, nil), (nil, nil):
                (knownKeys.max() ?? -1) + 1
            case let (nil, next?):
                knownKeys.filter { $0 < next }.max().map { ($0 + next) / 2 } ?? next - 1
            }
        }
    }

    /// Where a restored rail goes: before the first rail that came after it.
    private func insertionIndex(forRail railID: String, in sections: [YouTubeHomeSection]) -> Int {
        guard let key = self.railOrder[railID] else { return sections.count }
        return sections.firstIndex { (self.railOrder[$0.id] ?? .infinity) > key } ?? sections.count
    }

    private static func add(_ id: String, to counts: inout [String: Int]) {
        counts[id, default: 0] += 1
    }

    private static func remove(_ id: String, from counts: inout [String: Int]) {
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
    }

    private static func removals(
        in videos: [YouTubeVideo],
        matching matches: (YouTubeVideo) -> Bool
    ) -> [YouTubeFeedbackDismissal.Removal] {
        videos.enumerated()
            .filter { matches($0.element) }
            .map { YouTubeFeedbackDismissal.Removal(index: $0.offset, video: $0.element) }
    }

    /// One removal per video, keeping the first.
    private static func uniqued(_ removals: [YouTubeFeedbackDismissal.Removal]) -> [YouTubeFeedbackDismissal.Removal] {
        var seen: Set<String> = []
        return removals.filter { seen.insert($0.video.videoId).inserted }
    }

    /// Puts each card back before the first card that came after it. A card
    /// with no learned key falls back to its old index.
    private static func reinserting(
        _ removals: [YouTubeFeedbackDismissal.Removal],
        into videos: [YouTubeVideo],
        order: [String: Double]
    ) -> [YouTubeVideo] {
        var result = videos
        var present = Set(videos.map(\.videoId))
        let sorted = removals.sorted {
            (order[$0.video.videoId] ?? Double($0.index)) < (order[$1.video.videoId] ?? Double($1.index))
        }
        for removal in sorted where present.insert(removal.video.videoId).inserted {
            let index = if let key = order[removal.video.videoId] {
                result.firstIndex { (order[$0.videoId] ?? .infinity) > key } ?? result.count
            } else {
                min(removal.index, result.count)
            }
            result.insert(removal.video, at: index)
        }
        return result
    }
}
