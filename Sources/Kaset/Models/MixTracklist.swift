import Foundation

// MARK: - MixTrackEntry

/// A single sub-track within a long mix video (e.g., a DJ set or compilation).
/// Each entry maps a time range within the video to an artist and title,
/// enabling per-sub-track scrobbling instead of scrobbling the entire mix as one track.
struct MixTrackEntry: Identifiable, Hashable {
    let id: UUID
    /// Start time in seconds from the beginning of the video.
    let startTime: TimeInterval
    /// End time in seconds. Nil means "until the next entry or end of video."
    let endTime: TimeInterval?
    /// Track title (without the artist prefix).
    let title: String
    /// Artist name, if parsed from the chapter title or description.
    /// Falls back to the mix uploader name when parsing can't separate artist from title.
    let artist: String?
    /// Where this entry was parsed from.
    let source: Source

    enum Source: String, Hashable {
        case chapters
        case description
    }

    /// Duration of this sub-track in seconds, if end time is known.
    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime - self.startTime
    }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval?,
        title: String,
        artist: String?,
        source: Source
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.artist = artist
        self.source = source
    }

    /// Creates a MixTrackEntry from a YouTubeChapter title by splitting on a common dash separator.
    /// If the title has no dash, the full title is used as the track title
    /// and the artist is left nil (caller should provide a fallback).
    init(fromChapterTitle title: String, startTime: TimeInterval, endTime: TimeInterval?) {
        let parsed = Self.parseArtistTitle(from: title)
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.source = .chapters
        self.artist = parsed.artist
        self.title = parsed.title
    }

    /// Splits a chapter/description label like "Artist - Title" into its parts, trimming whitespace.
    /// Recognizes spaced ASCII plus en-dash, em-dash, and minus-sign separators with or without
    /// spaces. A bare ASCII hyphen stays ambiguous (`Part-1` is not necessarily artist/title). If
    /// no separator is found, the whole string is the title and the artist is nil (the caller
    /// supplies a fallback). Shared by the chapter and description tracklist tiers.
    static func parseArtistTitle(from raw: String) -> (artist: String?, title: String) {
        let spacedSeparators = [" - ", " – ", " — ", " − "]
        let unspacedUnicodeSeparators = ["–", "—", "−"]
        let spacedRange = spacedSeparators
            .compactMap { raw.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        let fallbackRange = unspacedUnicodeSeparators
            .compactMap { raw.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let dashRange = spacedRange ?? fallbackRange else {
            return (nil, raw.trimmingCharacters(in: .whitespaces))
        }
        let artist = raw[..<dashRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let title = raw[dashRange.upperBound...].trimmingCharacters(in: .whitespaces)
        return (artist.isEmpty ? nil : artist, title)
    }
}

// MARK: - MixTracklist

/// A parsed tracklist for a long mix video, containing sub-tracks with timestamps.
/// Used by `ScrobblingCoordinator` to scrobble individual tracks within a mix
/// instead of scrobbling the entire video as a single entry.
struct MixTracklist: Hashable {
    /// The YouTube video ID this tracklist belongs to.
    let videoId: String
    /// Sub-tracks sorted by start time.
    let entries: [MixTrackEntry]
    /// Where the tracklist was parsed from.
    let source: MixTrackEntry.Source
    /// Whether an explicit Tracklist/Setlist heading established description-list intent.
    let hasExplicitTracklistSignal: Bool

    init(
        videoId: String,
        entries: [MixTrackEntry],
        source: MixTrackEntry.Source,
        hasExplicitTracklistSignal: Bool = false
    ) {
        self.videoId = videoId
        let preservesHeadedDescriptionTitles = source == .description && hasExplicitTracklistSignal
        self.entries = entries
            .filter {
                !$0.title.isEmpty
                    && ($0.artist != nil
                        || preservesHeadedDescriptionTitles
                        || !Self.isGenericNavigationTitle($0.title))
            }
            .sorted { $0.startTime < $1.startTime }
        self.source = source
        self.hasExplicitTracklistSignal = hasExplicitTracklistSignal
    }

    /// Greatest timestamp established by the tracklist itself. This is a lower bound for the
    /// parent video's duration: a chapter starting or ending after a threshold proves the video is
    /// at least that long even when the player has not published its duration yet.
    var knownDurationLowerBound: TimeInterval? {
        self.entries
            .map { max($0.startTime, $0.endTime ?? $0.startTime) }
            .max()
    }

    /// Find the entry active at a given playback position (seconds from start).
    /// Returns the last entry whose startTime is <= progress, or nil if progress
    /// is before the first entry.
    func entry(at progress: TimeInterval) -> MixTrackEntry? {
        // Binary search for the last entry with startTime <= progress
        guard let firstEntry = self.entries.first, progress >= firstEntry.startTime else { return nil }

        var low = 0
        var high = self.entries.count - 1
        var result = 0

        while low <= high {
            let mid = (low + high) / 2
            if self.entries[mid].startTime <= progress {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let entry = self.entries[result]
        if let endTime = entry.endTime, progress >= endTime {
            return nil
        }
        return entry
    }

    /// Resolves duration from an explicit end, the next entry, or the parent video's final bound.
    func effectiveDuration(for entry: MixTrackEntry, videoDuration: TimeInterval?) -> TimeInterval? {
        guard let endTime = self.effectiveEndTime(for: entry, videoDuration: videoDuration) else { return nil }
        return endTime - entry.startTime
    }

    /// Resolves an entry's playback boundary from its explicit end, next entry, or parent video.
    func effectiveEndTime(for entry: MixTrackEntry, videoDuration: TimeInterval?) -> TimeInterval? {
        if let endTime = entry.endTime {
            return endTime
        }

        if let index = self.entries.firstIndex(where: { $0.id == entry.id }),
           self.entries.indices.contains(index + 1)
        {
            let nextStart = self.entries[index + 1].startTime
            if nextStart > entry.startTime {
                return nextStart
            }
        }

        guard self.entries.last?.id == entry.id,
              let videoDuration,
              videoDuration > entry.startTime
        else { return nil }

        return videoDuration
    }

    /// Minimum entry and identified-track count for a tracklist to be treated as a mix.
    /// Requiring structured artist/title labels avoids scrobbling generic intro/verse/outro or
    /// podcast-navigation chapters as if they were individual songs.
    static let minEntryCount = 3

    /// Whether this tracklist has enough entries and a sufficiently strong artist/title signal.
    var isMix: Bool {
        guard self.entries.count >= Self.minEntryCount else { return false }
        if self.source == .description, self.hasExplicitTracklistSignal {
            return true
        }
        let parsedArtistCount = self.entries.count { $0.artist != nil }
        return parsedArtistCount * 2 >= self.entries.count
    }

    private static func isGenericNavigationTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let exactLabels: Set = [
            "intro", "introduction", "outro", "verse", "chorus", "bridge", "interlude",
            "opening", "closing", "credits", "main section", "q&a", "qa",
        ]
        if exactLabels.contains(normalized) {
            return true
        }
        for prefix in [
            "chapter ", "chapter-", "part ", "part-", "section ", "section-",
            "segment ", "segment-", "topic ", "topic-",
        ] where normalized.hasPrefix(prefix) {
            let suffix = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if Int(suffix) != nil {
                return true
            }
            if !suffix.isEmpty,
               suffix == suffix.uppercased(),
               suffix.range(
                   of: #"^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"#,
                   options: .regularExpression
               ) != nil
            {
                return true
            }
        }
        return false
    }
}
