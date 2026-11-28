import Foundation

extension ParsingHelpers {
    static func extractPlaylistAuthor(from runs: [[String: Any]]) -> Artist? {
        if let navigable = extractFirstNavigableArtist(from: runs) {
            return navigable
        }

        let hasDedicatedSeparatorRun = runs.contains { run in
            guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return text == "•" || text == "·"
        }

        if hasDedicatedSeparatorRun {
            let segments = runs.split(whereSeparator: { run in
                guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return text == "•" || text == "·"
            }).map { segment in
                segment.compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            for segment in segments {
                guard Self.isPlaylistAuthorSegmentCandidate(segment) else { continue }
                return Artist.inline(name: segment, namespace: "playlist-author")
            }

            return nil
        }

        let joined = runs.compactMap { $0["text"] as? String }.joined()
        return Self.extractPlaylistAuthor(fromText: joined)
    }

    static func extractPlaylistAuthor(fromText text: String) -> Artist? {
        guard let name = normalizedLegacyPlaylistAuthorName(text) else {
            return nil
        }
        return Artist.inline(name: name, namespace: "playlist-author")
    }

    static func normalizedLegacyPlaylistAuthorName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rawSegments = Self.splitPreservingDelimiters(trimmed)
        var start = 0
        var end = rawSegments.count
        while start < end, !Self.isPlaylistAuthorSegmentCandidate(rawSegments[start].text) {
            start += 1
        }
        while end > start, !Self.isPlaylistAuthorSegmentCandidate(rawSegments[end - 1].text) {
            end -= 1
        }
        guard start < end else { return nil }
        let slice = rawSegments[start ..< end]
        var result = ""
        for (offset, part) in slice.enumerated() {
            if offset > 0 {
                result += part.leadingDelimiter
            }
            result += part.text
        }
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private struct DelimitedSegment {
        let leadingDelimiter: String
        let text: String
    }

    private static func splitPreservingDelimiters(_ text: String) -> [DelimitedSegment] {
        var result: [DelimitedSegment] = []
        var pendingDelimiter = ""
        var current = ""
        for character in text {
            if character == "•" || character == "·" {
                let trimmedSegment = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSegment.isEmpty {
                    result.append(DelimitedSegment(leadingDelimiter: pendingDelimiter, text: trimmedSegment))
                }
                pendingDelimiter = " \(character) "
                current = ""
            } else {
                current.append(character)
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            result.append(DelimitedSegment(leadingDelimiter: pendingDelimiter, text: trailing))
        }
        return result
    }

    static func extractPlaylistAuthor(from data: [String: Any]) -> Artist? {
        if let subtitle = data["subtitle"] as? [String: Any],
           let runs = subtitle["runs"] as? [[String: Any]]
        {
            return self.extractPlaylistAuthor(from: runs)
        }
        return Self.extractPlaylistAuthorFromFlexColumns(data)
    }

    static func extractPlaylistAuthorFromFlexColumns(_ data: [String: Any]) -> Artist? {
        guard let flexColumns = data["flexColumns"] as? [[String: Any]],
              flexColumns.count > 1,
              let renderer = flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]]
        else {
            return nil
        }
        return Self.extractPlaylistAuthor(from: runs)
    }

    private static let localizedTrackCountUnits: Set<String> = [
        "song", "songs", "track", "tracks", "video", "videos", "episode", "episodes",
        "şarkı", "canción", "canciones", "chanson", "chansons", "titre", "titres",
        "titel", "lied", "lieder", "brano", "brani", "canzone", "canzoni",
        "música", "músicas", "faixa", "faixas", "nummer", "nummers",
        "utwór", "utwory", "utworów", "piosenka", "piosenki", "piosenek",
        "låt", "låtar", "трек", "трека", "треков", "песня", "песни", "песен",
        "пісня", "пісні", "пісень", "lagu", "أغنية", "أغاني", "مقطع", "مقاطع",
        "曲", "首歌曲", "곡", "首",
    ]

    private static func isPlaylistAuthorSegmentCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "•",
              trimmed != "·",
              !Self.isMetadataText(trimmed),
              Self.extractSongCount(from: trimmed) == nil,
              Self.parseDuration(trimmed) == nil,
              !Self.isLocalizedTrackCountSegment(trimmed)
        else {
            return false
        }

        let lowercased = trimmed.lowercased()
        let nonCreatorKeywords: Set = [
            "playlist", "album", "single", "ep", "song", "uploads", "radio", "mix",
            "プレイリスト", "再生リスト", "播放列表", "播放清單", "歌单", "歌單", "재생목록",
        ]
        if nonCreatorKeywords.contains(lowercased) {
            return false
        }

        return true
    }

    private static func isLocalizedTrackCountSegment(_ text: String) -> Bool {
        if SearchResponseParser.hasLocalizedCountUnit(text) {
            return true
        }
        let normalized = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains(where: \.isNumber),
              let unit = normalized.split(whereSeparator: { character in
                  character.isWhitespace || character.isNumber || character == "." || character == "," || character == "+"
              }).last.map(String.init)
        else {
            return false
        }
        return Self.localizedTrackCountUnits.contains(unit)
    }
}
