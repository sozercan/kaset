import Foundation

extension ParsingHelpers {
    /// Extracts the audio-recording video ID advertised by a track row's
    /// "View song credits" menu entry.
    ///
    /// YouTube Music builds the track-credits browse ID by prefixing `MPTC` to the
    /// video ID of the song's *audio* recording. On albums whose rows are official
    /// music videos (`MUSIC_VIDEO_TYPE_OMV`), that suffix is the audio counterpart
    /// of the same track; on ordinary audio rows it simply repeats the row's own
    /// video ID.
    ///
    /// The credits entry is matched on its `MUSIC_PAGE_TYPE_TRACK_CREDITS` page type
    /// rather than its label, so this keeps working under any content language.
    static func extractTrackCreditsVideoId(from data: [String: Any]) -> String? {
        guard let menu = data["menu"] as? [String: Any],
              let menuRenderer = menu["menuRenderer"] as? [String: Any],
              let items = menuRenderer["items"] as? [[String: Any]]
        else {
            return nil
        }

        for item in items {
            guard let navigationItem = item["menuNavigationItemRenderer"] as? [String: Any],
                  let endpoint = navigationItem["navigationEndpoint"] as? [String: Any],
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  self.extractPageType(from: browseEndpoint) == self.trackCreditsPageType,
                  let browseId = browseEndpoint["browseId"] as? String,
                  browseId.hasPrefix(self.trackCreditsBrowseIdPrefix)
            else {
                continue
            }

            let videoId = String(browseId.dropFirst(self.trackCreditsBrowseIdPrefix.count))
            return videoId.isEmpty ? nil : videoId
        }

        return nil
    }

    /// Page type identifying a track-credits browse destination.
    private static let trackCreditsPageType = "MUSIC_PAGE_TYPE_TRACK_CREDITS"

    /// Prefix YouTube Music prepends to a video ID to form its credits browse ID.
    private static let trackCreditsBrowseIdPrefix = "MPTC"
}
