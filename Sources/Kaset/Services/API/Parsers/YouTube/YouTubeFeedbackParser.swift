import Foundation

/// Parses recommendation-feedback entries ("Not interested",
/// "Don't recommend channel") from a video lockup's overflow menu.
///
/// Verified against signed-in Home and watch-next responses (November 2026).
/// The menu is a sheet of `listItemViewModel`s at
/// `metadata.lockupMetadataViewModel.menuButton.buttonViewModel.onTap
/// .innertubeCommand.showSheetCommand.panelLoadingStrategy.inlineContent
/// .sheetViewModel.content.listViewModel.listItems`. Feedback entries carry
/// `rendererContext.commandContext.onTap.innertubeCommand.feedbackEndpoint`.
///
/// Entries are classified by their icon, which stays the same across
/// languages while the titles are localized:
/// - `HIDE`: "Not interested" on Home and watch-next ("Hide" on the
///   subscriptions feed)
/// - `REMOVE`: "Don't recommend channel"
/// - `DELETE`: "Remove from watch history" on the history feed, which is
///   deliberately not surfaced here
enum YouTubeFeedbackParser {
    /// Feedback actions from a video `lockupViewModel`, in menu order.
    static func actions(fromLockup lockup: [String: Any]) -> [YouTubeFeedbackAction] {
        let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"]
            as? [String: Any]
        let menuButton = (metadata?["menuButton"] as? [String: Any])?["buttonViewModel"]
            as? [String: Any]
        let menuCommand = (menuButton?["onTap"] as? [String: Any])?["innertubeCommand"]
            as? [String: Any]
        return self.actions(fromSheetCommand: menuCommand)
    }

    /// Feedback actions from an `innertubeCommand` that opens a menu sheet
    /// (`showSheetCommand`).
    static func actions(fromSheetCommand command: [String: Any]?) -> [YouTubeFeedbackAction] {
        let sheet = (
            ((command?["showSheetCommand"] as? [String: Any])?["panelLoadingStrategy"]
                as? [String: Any])?["inlineContent"] as? [String: Any]
        )?["sheetViewModel"] as? [String: Any]
        let listItems = (
            (sheet?["content"] as? [String: Any])?["listViewModel"] as? [String: Any]
        )?["listItems"] as? [[String: Any]] ?? []

        var actions: [YouTubeFeedbackAction] = []
        for item in listItems {
            guard let listItem = item["listItemViewModel"] as? [String: Any],
                  let action = self.action(fromListItem: listItem),
                  !actions.contains(where: { $0.kind == action.kind })
            else {
                continue
            }
            actions.append(action)
        }
        return actions
    }

    // MARK: - Private

    private static func action(fromListItem listItem: [String: Any]) -> YouTubeFeedbackAction? {
        guard let kind = self.kind(forIcon: self.iconName(of: listItem)),
              let title = (listItem["title"] as? [String: Any])?["content"] as? String,
              !title.isEmpty
        else {
            return nil
        }

        let command = (
            ((listItem["rendererContext"] as? [String: Any])?["commandContext"]
                as? [String: Any])?["onTap"] as? [String: Any]
        )?["innertubeCommand"] as? [String: Any]
        guard let feedbackEndpoint = command?["feedbackEndpoint"] as? [String: Any],
              let feedbackToken = feedbackEndpoint["feedbackToken"] as? String,
              !feedbackToken.isEmpty
        else {
            return nil
        }

        let notification = self.notification(in: feedbackEndpoint)
        let undoButton = self.undoButton(in: notification)

        return YouTubeFeedbackAction(
            kind: kind,
            title: title,
            feedbackToken: feedbackToken,
            undoToken: undoButton?.token,
            confirmationText: YouTubeItemParser.text(from: notification?["responseText"]),
            undoTitle: undoButton?.title
        )
    }

    private static func iconName(of listItem: [String: Any]) -> String? {
        let sources = (listItem["leadingImage"] as? [String: Any])?["sources"] as? [[String: Any]]
        return (sources?.first?["clientResource"] as? [String: Any])?["imageName"] as? String
    }

    private static func kind(forIcon icon: String?) -> YouTubeFeedbackAction.Kind? {
        switch icon {
        case "HIDE":
            .notInterested
        case "REMOVE":
            .dontRecommendChannel
        default:
            nil
        }
    }

    /// The `notificationMultiActionRenderer` YouTube swaps in for the hidden
    /// card ("Video removed · Undo").
    private static func notification(in feedbackEndpoint: [String: Any]) -> [String: Any]? {
        let actions = feedbackEndpoint["actions"] as? [[String: Any]] ?? []
        for action in actions {
            let item = (action["replaceEnclosingAction"] as? [String: Any])?["item"] as? [String: Any]
            if let notification = item?["notificationMultiActionRenderer"] as? [String: Any] {
                return notification
            }
        }
        return nil
    }

    private static func undoButton(in notification: [String: Any]?) -> (token: String, title: String?)? {
        let buttons = notification?["buttons"] as? [[String: Any]] ?? []
        for button in buttons {
            guard let renderer = button["buttonRenderer"] as? [String: Any],
                  let undo = (renderer["serviceEndpoint"] as? [String: Any])?["undoFeedbackEndpoint"]
                  as? [String: Any],
                  let token = undo["undoToken"] as? String,
                  !token.isEmpty
            else {
                continue
            }
            return (token, YouTubeItemParser.text(from: renderer["text"]))
        }
        return nil
    }
}
