import Foundation

/// Parses the "Song credits" dialog returned by browsing an `MPTC` browse ID.
enum TrackCreditsParser {
    static func parse(_ data: [String: Any]) -> TrackCredits {
        guard let dialog = creditsDialog(in: data),
              let sections = dialog["sections"] as? [[String: Any]]
        else {
            return .unavailable
        }

        let parsedSections = sections.compactMap { section -> TrackCredits.Section? in
            guard let renderer = section["dismissableDialogContentSectionRenderer"] as? [String: Any] else {
                return nil
            }
            let title = Self.text(of: renderer["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let names = Self.text(of: renderer["subtitle"])
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !title.isEmpty, !names.isEmpty else { return nil }
            return TrackCredits.Section(title: title, names: names)
        }

        return TrackCredits(title: dialog["title"] as? String, sections: parsedSections)
    }

    private static func creditsDialog(in data: [String: Any]) -> [String: Any]? {
        let actions = data["onResponseReceivedActions"] as? [[String: Any]] ?? []
        for action in actions {
            guard let openPopup = action["openPopupAction"] as? [String: Any],
                  let popup = openPopup["popup"] as? [String: Any],
                  let dialog = popup["dismissableDialogRenderer"] as? [String: Any]
            else {
                continue
            }
            return dialog
        }
        return nil
    }

    private static func text(of value: Any?) -> String {
        guard let container = value as? [String: Any],
              let runs = container["runs"] as? [[String: Any]]
        else {
            return ""
        }
        return runs.compactMap { $0["text"] as? String }.joined()
    }
}
