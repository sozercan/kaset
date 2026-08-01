// MARK: - Playlist Parsing

extension ParsingHelpers {
    /// Extracts the playlist-item-specific `setVideoId`, required to remove the correct
    /// occurrence of a track from a playlist (the same song can appear more than once).
    /// Only present on playlist track rows, not search results or other song contexts.
    static func extractPlaylistSetVideoId(from data: [String: Any]) -> String? {
        if let playlistItemData = data["playlistItemData"] as? [String: Any],
           let playlistSetVideoId = playlistItemData["playlistSetVideoId"] as? String,
           !playlistSetVideoId.isEmpty
        {
            return playlistSetVideoId
        }

        return Self.extractPlaylistSetVideoIdFromEditEndpoint(in: data)
    }

    private static func extractPlaylistSetVideoIdFromEditEndpoint(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let editEndpoint = dictionary["playlistEditEndpoint"] as? [String: Any],
               let actions = editEndpoint["actions"] as? [[String: Any]]
            {
                for action in actions where action["action"] as? String == "ACTION_REMOVE_VIDEO" {
                    if let setVideoId = action["setVideoId"] as? String, !setVideoId.isEmpty {
                        return setVideoId
                    }
                }
            }

            for nestedValue in dictionary.values {
                if let setVideoId = Self.extractPlaylistSetVideoIdFromEditEndpoint(in: nestedValue) {
                    return setVideoId
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let setVideoId = Self.extractPlaylistSetVideoIdFromEditEndpoint(in: item) {
                    return setVideoId
                }
            }
        }

        return nil
    }
}
