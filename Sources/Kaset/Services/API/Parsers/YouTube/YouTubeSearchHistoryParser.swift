import Foundation

/// Parses the signed-in account's YouTube search history from the web
/// search box's suggest endpoint.
///
/// Verified against www.youtube.com (November 2026). Focusing the empty
/// search box sends
/// `GET /complete/search?ds=yt&client=youtube&gs_ri=youtube&tok=<token>&q=&cp=0`
/// with the account cookies. `tok` is `ytcfg.SBOX_SETTINGS.PSUGGEST_TOKEN`
/// from any signed-in YouTube page; without it the response is empty.
///
/// The body is JSONP: `window.google.ac.h(["", [items…], {…}])`. Each item
/// is `[query, type, [subtypes…], {extras}?]`. Personal history entries have
/// type `35` and subtype `39`. Generic suggestions have type `0` and never
/// carry subtype `39`.
enum YouTubeSearchHistoryParser {
    private static let personalHistoryType = 35
    private static let personalHistorySubtype = 39

    /// History queries from a suggest response, most recent first, without
    /// duplicates. Returns an empty array for unexpected shapes.
    static func queries(fromSuggestResponse data: Data) -> [String] {
        guard let body = String(data: data, encoding: .utf8),
              let open = body.firstIndex(of: "("),
              let close = body.lastIndex(of: ")"),
              open < close
        else {
            return []
        }

        let payload = Data(body[body.index(after: open) ..< close].utf8)
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [Any],
              root.count > 1,
              let items = root[1] as? [Any]
        else {
            return []
        }

        var seen: Set<String> = []
        var queries: [String] = []
        for case let item as [Any] in items {
            guard let query = item.first as? String,
                  self.isPersonalHistory(item)
            else {
                continue
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            queries.append(trimmed)
        }
        return queries
    }

    /// The suggest personalization token (`PSUGGEST_TOKEN`) from a YouTube
    /// page's inline `ytcfg`, or `nil` when the page has none (signed out, or
    /// a consent interstitial).
    static func suggestToken(fromHTML html: String) -> String? {
        let marker = "\"PSUGGEST_TOKEN\":\""
        guard let markerRange = html.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        guard let valueEnd = html[valueStart...].firstIndex(of: "\"") else { return nil }
        let token = String(html[valueStart ..< valueEnd])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !token.isEmpty,
              token.count <= 256,
              token.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            return nil
        }
        return token
    }

    // MARK: - Private

    private static func isPersonalHistory(_ item: [Any]) -> Bool {
        let type = item.count > 1 ? item[1] as? Int : nil
        let subtypes = item.count > 2 ? item[2] as? [Int] ?? [] : []
        return type == self.personalHistoryType || subtypes.contains(self.personalHistorySubtype)
    }
}
