import Foundation

extension ParsingHelpers {
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

    private static let trackCreditsPageType = "MUSIC_PAGE_TYPE_TRACK_CREDITS"

    private static let trackCreditsBrowseIdPrefix = "MPTC"
}
