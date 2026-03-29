import Foundation

/// Parser for YouTube Music accounts list API responses.
///
/// Parses the multi-page menu response containing the list of available accounts
/// (primary and brand accounts) for the account switcher feature.
enum AccountsListParser {
    private static let logger = DiagnosticsLogger.api

    // MARK: - Public API

    /// Parses the accounts list API response.
    ///
    /// - Parameter json: The raw JSON response from the accounts list API.
    /// - Returns: An `AccountsListResponse` containing parsed accounts, or an empty response on failure.
    static func parse(_ json: [String: Any]) -> AccountsListResponse {
        // Navigate to the multi-page menu renderer
        guard let actions = json["actions"] as? [[String: Any]],
              let firstAction = actions.first,
              let getMultiPageMenuAction = firstAction["getMultiPageMenuAction"] as? [String: Any],
              let menu = getMultiPageMenuAction["menu"] as? [String: Any],
              let multiPageMenuRenderer = menu["multiPageMenuRenderer"] as? [String: Any],
              let sections = multiPageMenuRenderer["sections"] as? [[String: Any]]
        else {
            self.logger.debug("AccountsListParser: Failed to navigate to sections. Top keys: \(json.keys.sorted())")
            return AccountsListResponse(googleEmail: nil, accounts: [])
        }

        var googleEmail: String?
        var accounts: [UserAccount] = []

        // Parse each section
        for section in sections {
            guard let accountSectionListRenderer = section["accountSectionListRenderer"] as? [String: Any] else {
                continue
            }

            // Extract Google email from header
            if googleEmail == nil {
                googleEmail = Self.extractGoogleEmail(from: accountSectionListRenderer)
            }

            // Parse account items from contents
            if let contents = accountSectionListRenderer["contents"] as? [[String: Any]] {
                for content in contents {
                    if let accountItemSection = content["accountItemSectionRenderer"] as? [String: Any],
                       let accountItems = accountItemSection["contents"] as? [[String: Any]]
                    {
                        for accountItemWrapper in accountItems {
                            if let account = Self.parseAccountItem(accountItemWrapper) {
                                accounts.append(account)
                            }
                        }
                    }
                }
            }
        }

        self.logger.debug("AccountsListParser: Parsed \(accounts.count) accounts")
        return AccountsListResponse(googleEmail: googleEmail, accounts: accounts)
    }

    // MARK: - Private Helpers

    /// Extracts the Google email from the account section header.
    private static func extractGoogleEmail(from accountSection: [String: Any]) -> String? {
        guard let header = accountSection["header"] as? [String: Any],
              let googleAccountHeaderRenderer = header["googleAccountHeaderRenderer"] as? [String: Any],
              let email = googleAccountHeaderRenderer["email"] as? [String: Any],
              let runs = email["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let emailText = firstRun["text"] as? String
        else {
            return nil
        }
        return emailText
    }

    /// Parses a single account item from the API response.
    ///
    /// - Parameter item: The account item wrapper dictionary containing `accountItem`.
    /// - Returns: A `UserAccount` if parsing succeeds, nil otherwise.
    private static func parseAccountItem(_ item: [String: Any]) -> UserAccount? {
        guard let accountItem = item["accountItem"] as? [String: Any] else {
            return nil
        }

        // Extract account name (required)
        guard let accountNameData = accountItem["accountName"] as? [String: Any],
              let nameRuns = accountNameData["runs"] as? [[String: Any]],
              let firstNameRun = nameRuns.first,
              let name = firstNameRun["text"] as? String,
              !name.isEmpty
        else {
            self.logger.debug("AccountsListParser: Missing account name")
            return nil
        }

        // Extract channel handle (optional)
        var handle: String?
        if let channelHandleData = accountItem["channelHandle"] as? [String: Any],
           let handleRuns = channelHandleData["runs"] as? [[String: Any]],
           let firstHandleRun = handleRuns.first,
           let handleText = firstHandleRun["text"] as? String
        {
            handle = handleText
        }

        // Extract thumbnail URL (optional)
        var thumbnailURL: URL?
        if let accountPhoto = accountItem["accountPhoto"] as? [String: Any],
           let thumbnails = accountPhoto["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            thumbnailURL = URL(string: ParsingHelpers.normalizeURL(urlString))
        }

        // Extract isSelected (defaults to false)
        let isSelected = accountItem["isSelected"] as? Bool ?? false

        // Extract brandId from pageIdToken (nil for primary accounts)
        let brandId = Self.extractBrandId(from: accountItem)

        return UserAccount.from(
            name: name,
            handle: handle,
            brandId: brandId,
            thumbnailURL: thumbnailURL,
            isSelected: isSelected
        )
    }

    /// Extracts the brand ID from the service endpoint's supported tokens.
    ///
    /// Primary accounts don't have a pageIdToken, so this returns nil for them.
    private static func extractBrandId(from accountItem: [String: Any]) -> String? {
        guard let serviceEndpoint = accountItem["serviceEndpoint"] as? [String: Any],
              let selectActiveIdentityEndpoint = serviceEndpoint["selectActiveIdentityEndpoint"] as? [String: Any],
              let supportedTokens = selectActiveIdentityEndpoint["supportedTokens"] as? [[String: Any]]
        else {
            return nil
        }

        // Look for pageIdToken in supported tokens
        for token in supportedTokens {
            if let pageIdToken = token["pageIdToken"] as? [String: Any],
               let pageId = pageIdToken["pageId"] as? String
            {
                return pageId
            }
        }

        return nil
    }
}
