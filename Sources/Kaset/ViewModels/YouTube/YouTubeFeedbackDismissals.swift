import Foundation

// MARK: - YouTubeFeedbackDismissal

/// Cards removed from a feed after recommendation feedback, kept so the
/// dismissal can be undone and the cards restored to their places.
struct YouTubeFeedbackDismissal: Identifiable {
    /// A removed card and the index it had in its list.
    struct Removal {
        let index: Int
        let video: YouTubeVideo
    }

    /// A rail the dismissal emptied and removed, with its position in the
    /// section list and its cards as they were before the dismissal.
    struct RemovedSection {
        let index: Int
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

    /// Cards and rails an undo could not restore yet because another
    /// dismissal still covered them. Later undos restore them once nothing
    /// covers them anymore.
    private var heldGridRemovals: [YouTubeFeedbackDismissal.Removal] = []
    private var heldSectionRemovals: [String: [YouTubeFeedbackDismissal.Removal]] = [:]
    private var heldSections: [YouTubeFeedbackDismissal.RemovedSection] = []

    /// A stable order key per rail, learned from every rail list seen on
    /// dismiss and undo. Restored rails go back between the same rails as
    /// before, even when undos finish out of order.
    private var railOrder: [String: Double] = [:]

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
        self.learnRailOrder(sections)
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
        for (index, section) in sections.enumerated() {
            guard sectionRemovals[section.id] != nil else {
                remainingSections.append(section)
                continue
            }
            let remaining = section.videos.filter { !matches($0) }
            if remaining.isEmpty {
                removedSections.append(.init(index: index, section: section))
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

        // This dismissal's cards plus everything earlier undos had to hold.
        let gridCandidates = self.heldGridRemovals + dismissal.gridRemovals
        self.heldGridRemovals = gridCandidates.filter { self.isDismissed($0.video) }
        videos = Self.reinserting(gridCandidates.filter { !self.isDismissed($0.video) }, into: videos)

        // Rail cards waiting to come back, keyed by rail. Cards whose rail is
        // missing right now stay held for when the rail returns.
        var pendingRailRemovals = self.heldSectionRemovals.merging(dismissal.sectionRemovals) { $0 + $1 }
        sections = sections.map { section in
            guard let removals = pendingRailRemovals[section.id] else { return section }
            pendingRailRemovals[section.id] = removals.filter { self.isDismissed($0.video) }
            let restorable = removals.filter { !self.isDismissed($0.video) }
            return section.replacingVideos(Self.reinserting(restorable, into: section.videos))
        }

        self.learnRailOrder(sections)
        var stillHeldSections: [YouTubeFeedbackDismissal.RemovedSection] = []
        let removedCandidates = (self.heldSections + dismissal.removedSections).sorted { $0.index < $1.index }
        for removed in removedCandidates where !sections.contains(where: { $0.id == removed.section.id }) {
            let railID = removed.section.id
            let snapshotRemovals = removed.section.videos.enumerated()
                .map { YouTubeFeedbackDismissal.Removal(index: $0.offset, video: $0.element) }
            let candidates = snapshotRemovals + (pendingRailRemovals[railID] ?? [])
            let restorable = candidates.filter { !self.isDismissed($0.video) }
            guard !restorable.isEmpty else {
                stillHeldSections.append(removed)
                continue
            }
            pendingRailRemovals[railID] = candidates.filter { self.isDismissed($0.video) }
            sections.insert(
                removed.section.replacingVideos(Self.reinserting(restorable, into: [])),
                at: self.insertionIndex(for: removed, in: sections)
            )
        }
        self.heldSectionRemovals = pendingRailRemovals.filter { !$0.value.isEmpty }
        self.heldSections = stillHeldSections
    }

    /// Gives every rail not seen before an order key between its known
    /// neighbors in this list. Keys of removed rails count too, so a new rail
    /// never takes a removed rail's place: one appended at the end goes after
    /// every known rail, and one inserted between neighbors goes before the
    /// next known key.
    private mutating func learnRailOrder(_ sections: [YouTubeHomeSection]) {
        for (index, section) in sections.enumerated() where self.railOrder[section.id] == nil {
            let order = self.railOrder
            let previousKey = sections[..<index].reversed().first { order[$0.id] != nil }.flatMap { order[$0.id] }
            let nextKey = sections[(index + 1)...].first { order[$0.id] != nil }.flatMap { order[$0.id] }
            let knownKeys = order.values
            self.railOrder[section.id] = switch (previousKey, nextKey) {
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
    /// The old index is the fallback for a rail with no known order.
    private func insertionIndex(
        for removed: YouTubeFeedbackDismissal.RemovedSection,
        in sections: [YouTubeHomeSection]
    ) -> Int {
        guard let key = self.railOrder[removed.section.id] else {
            return min(removed.index, sections.count)
        }
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

    private static func reinserting(
        _ removals: [YouTubeFeedbackDismissal.Removal],
        into videos: [YouTubeVideo]
    ) -> [YouTubeVideo] {
        var result = videos
        var present = Set(videos.map(\.videoId))
        for removal in removals.sorted(by: { $0.index < $1.index })
            where present.insert(removal.video.videoId).inserted
        {
            result.insert(removal.video, at: min(removal.index, result.count))
        }
        return result
    }
}
