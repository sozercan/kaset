import Foundation

// MARK: - WhatsNewProvider

/// Provides "What's New" entries from GitHub release notes, with a static fallback.
enum WhatsNewProvider {
    /// GitHub repo for fetching release notes.
    private static let owner = "sozercan"
    private static let repo = "kaset"

    /// Static fallback entries used when the network is unavailable.
    static let fallbackCollection: [WhatsNew] = [
        WhatsNew(
            version: "1.0.0",
            title: "Welcome to Kaset",
            features: [
                .init(
                    icon: "play.circle.fill",
                    title: "Background Playback",
                    subtitle: "Keep listening even when the window is closed"
                ),
                .init(
                    icon: "rectangle.grid.2x2.fill",
                    title: "Native Interface",
                    subtitle: "Built with SwiftUI for a true macOS experience"
                ),
                .init(
                    icon: "keyboard.fill",
                    title: "Media Keys",
                    subtitle: "Control playback with your keyboard"
                ),
                .init(
                    icon: "person.crop.circle.fill",
                    title: "Your Library",
                    subtitle: "Access your playlists and liked songs"
                ),
            ],
            learnMoreURL: URL(string: "https://github.com/sozercan/kaset/releases")
        ),
    ]

    // MARK: - Fetch from GitHub

    /// Fetches the release notes for the current app version from GitHub.
    /// Falls back to the static collection if the network request fails.
    static func fetchWhatsNew(
        for currentVersion: WhatsNew.Version = .current(),
        store: WhatsNewVersionStore = WhatsNewVersionStore()
    ) async -> WhatsNew? {
        guard !store.hasPresented(currentVersion) else {
            return nil
        }

        // Try fetching from GitHub releases
        if let dynamic = await self.fetchFromGitHub(for: currentVersion) {
            return dynamic
        }

        // Fall back to static collection
        return self.staticWhatsNew(for: currentVersion, store: store)
    }

    /// Version-gating against the static fallback collection (synchronous).
    static func staticWhatsNew(
        for currentVersion: WhatsNew.Version = .current(),
        store: WhatsNewVersionStore = WhatsNewVersionStore()
    ) -> WhatsNew? {
        guard !store.hasPresented(currentVersion) else {
            return nil
        }

        if let exact = self.fallbackCollection.first(where: { $0.version == currentVersion }) {
            return exact
        }

        let minorVersion = currentVersion.minorRelease
        guard !store.hasPresented(minorVersion) else {
            return nil
        }

        return self.fallbackCollection.first { $0.version == minorVersion }
    }

    // MARK: - GitHub API

    private static func fetchFromGitHub(for version: WhatsNew.Version) async -> WhatsNew? {
        // Try exact tag (v1.2.3), then minor (v1.2.0)
        let tags = [
            "v\(version.description)",
            "v\(version.minorRelease.description)",
        ]

        for tag in tags {
            if let whatsNew = await self.fetchRelease(tag: tag) {
                return whatsNew
            }
        }

        // Try latest release as last resort
        return await self.fetchLatestRelease()
    }

    /// Fetches a release by tag — useful for testing a specific version.
    static func fetchForTag(_ tag: String) async -> WhatsNew? {
        let urlString = "https://api.github.com/repos/\(self.owner)/\(self.repo)/releases/tags/\(tag)"
        guard let url = URL(string: urlString) else { return nil }
        return await self.performRequest(url: url)
    }

    private static func fetchRelease(tag: String) async -> WhatsNew? {
        await self.fetchForTag(tag)
    }

    private static func fetchLatestRelease() async -> WhatsNew? {
        let urlString = "https://api.github.com/repos/\(self.owner)/\(self.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }
        return await self.performRequest(url: url)
    }

    private static func performRequest(url: URL) async -> WhatsNew? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return nil
            }
            return self.parseRelease(data: data)
        } catch {
            DiagnosticsLogger.app.debug("Failed to fetch release notes: \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseRelease(data: Data) -> WhatsNew? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let body = json["body"] as? String,
              let htmlURL = json["html_url"] as? String
        else {
            return nil
        }

        let versionString = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let version = WhatsNew.Version(stringLiteral: versionString)
        let name = json["name"] as? String
        let title = name ?? "What's New in Kaset \(versionString)"

        return WhatsNew(
            version: version,
            title: title,
            releaseNotes: body,
            learnMoreURL: URL(string: htmlURL)
        )
    }
}
