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
    private var videoIDs: Set<String> = []
    private var channelIDs: Set<String> = []

    private var isEmpty: Bool {
        self.videoIDs.isEmpty && self.channelIDs.isEmpty
    }

    func isDismissed(_ video: YouTubeVideo) -> Bool {
        if self.videoIDs.contains(video.videoId) {
            return true
        }
        guard let channelID = video.channelId else { return false }
        return self.channelIDs.contains(channelID)
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
        let channelID = action.kind == .dontRecommendChannel ? video.channelId : nil
        self.videoIDs.insert(video.videoId)
        if let channelID {
            self.channelIDs.insert(channelID)
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
        sections = sections.compactMap { section in
            guard sectionRemovals[section.id] != nil else { return section }
            let remaining = section.videos.filter { !matches($0) }
            return remaining.isEmpty ? nil : section.replacingVideos(remaining)
        }

        return YouTubeFeedbackDismissal(
            action: action,
            videoID: video.videoId,
            channelID: channelID,
            gridRemovals: gridRemovals,
            sectionRemovals: sectionRemovals
        )
    }

    /// Forgets an undone dismissal and puts its cards back where they were.
    /// Rails the dismissal emptied were dropped; they return on the next refresh.
    mutating func undo(
        _ dismissal: YouTubeFeedbackDismissal,
        videos: inout [YouTubeVideo],
        sections: inout [YouTubeHomeSection]
    ) {
        self.videoIDs.remove(dismissal.videoID)
        if let channelID = dismissal.channelID {
            self.channelIDs.remove(channelID)
        }

        videos = Self.reinserting(dismissal.gridRemovals, into: videos)
        sections = sections.map { section in
            guard let removals = dismissal.sectionRemovals[section.id] else { return section }
            return section.replacingVideos(Self.reinserting(removals, into: section.videos))
        }
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
