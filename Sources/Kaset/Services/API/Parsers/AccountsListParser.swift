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

        // Extract identity tokens (brandId + server-issued switch URL) in one pass.
        let identity = Self.extractIdentityTokens(from: accountItem)

        return UserAccount.from(
            name: name,
            handle: handle,
            brandId: identity.brandId,
            thumbnailURL: thumbnailURL,
            isSelected: isSelected,
            signinURL: identity.signinURL
        )
    }

    /// Extracts identity material from `selectActiveIdentityEndpoint.supportedTokens`.
    ///
    /// - `brandId`: from `pageIdToken.pageId` (nil for the primary account, which
    ///   has no `pageIdToken`).
    /// - `signinURL`: from `accountSigninToken.signinUrl` — the server-issued
    ///   account-switch endpoint. Navigating a shared-cookie WebView to it
    ///   re-points the session's active delegated identity. Present for both
    ///   primary and brand accounts (the brand variant encodes a `pageid`).
    private static func extractIdentityTokens(
        from accountItem: [String: Any]
    ) -> (brandId: String?, signinURL: URL?) {
        guard let serviceEndpoint = accountItem["serviceEndpoint"] as? [String: Any],
              let activeIdentity = serviceEndpoint["selectActiveIdentityEndpoint"] as? [String: Any],
              let entries = activeIdentity["supportedTokens"] as? [[String: Any]]
        else {
            return (nil, nil)
        }

        var brandId: String?
        var signinURL: URL?
        for entry in entries {
            if brandId == nil,
               let pageIdToken = entry["pageIdToken"] as? [String: Any],
               let pageId = pageIdToken["pageId"] as? String
            {
                brandId = pageId
            }
            if signinURL == nil,
               let signinToken = entry["accountSigninToken"] as? [String: Any],
               let urlString = signinToken["signinUrl"] as? String
            {
                signinURL = Self.resolveSigninURL(urlString)
            }
        }
        return (brandId, signinURL)
    }

    /// Resolves an `accountSigninToken.signinUrl` into an absolute URL.
    ///
    /// The API returns this as a root-relative path (`/signin?...`); it must be
    /// resolved against the YouTube origin. Also handles protocol-relative and
    /// already-absolute forms defensively.
    static func resolveSigninURL(_ urlString: String, origin: String = "https://www.youtube.com") -> URL? {
        let resolvedURL: URL? = if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            URL(string: urlString)
        } else if urlString.hasPrefix("//") {
            URL(string: "https:" + urlString)
        } else if urlString.hasPrefix("/") {
            URL(string: urlString, relativeTo: URL(string: origin))?.absoluteURL
        } else {
            URL(string: urlString)
        }
        guard let resolvedURL, Self.isAllowedSigninURL(resolvedURL) else { return nil }
        return resolvedURL
    }

    static func isAllowedSigninURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host?.lowercased() == "www.youtube.com" &&
            url.path == "/signin"
    }
}
