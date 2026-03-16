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
        store: WhatsNewVersionStore = WhatsNewVersionStore(),
        respectingPresentedVersions: Bool = true,
        session: URLSession = .shared
    ) async -> WhatsNew? {
        if respectingPresentedVersions, store.hasPresented(currentVersion) {
            return nil
        }

        // Try fetching from GitHub releases
        if let dynamic = await Self.fetchFromGitHub(for: currentVersion, session: session) {
            return dynamic
        }

        // Fall back to static collection
        return Self.staticWhatsNew(
            for: currentVersion,
            store: store,
            respectingPresentedVersions: respectingPresentedVersions
        )
    }

    /// Version-gating against the static fallback collection (synchronous).
    static func staticWhatsNew(
        for currentVersion: WhatsNew.Version = .current(),
        store: WhatsNewVersionStore = WhatsNewVersionStore(),
        respectingPresentedVersions: Bool = true
    ) -> WhatsNew? {
        if respectingPresentedVersions, store.hasPresented(currentVersion) {
            return nil
        }

        if let exact = Self.fallbackCollection.first(where: { $0.version == currentVersion }) {
            return exact
        }

        let minorVersion = currentVersion.minorRelease
        if respectingPresentedVersions, store.hasPresented(minorVersion) {
            return nil
        }

        return Self.fallbackCollection.first { $0.version == minorVersion }
    }

    // MARK: - GitHub API

    private static func fetchFromGitHub(
        for version: WhatsNew.Version,
        session: URLSession = .shared
    ) async -> WhatsNew? {
        // Try exact tag (v1.2.3), then minor (v1.2.0)
        var tags: [String] = []

        for candidate in [version, version.minorRelease] {
            let tag = "v\(candidate.description)"
            if !tags.contains(tag) {
                tags.append(tag)
            }
        }

        for tag in tags {
            if let whatsNew = await Self.fetchRelease(tag: tag, session: session) {
                return whatsNew
            }
        }

        // Try latest release as last resort
        return await Self.fetchLatestRelease(session: session)
    }

    /// Fetches a release by tag — useful for testing a specific version.
    static func fetchForTag(_ tag: String, session: URLSession = .shared) async -> WhatsNew? {
        let urlString = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/tags/\(tag)"
        guard let url = URL(string: urlString) else { return nil }
        return await Self.performRequest(url: url, session: session)
    }

    private static func fetchRelease(tag: String, session: URLSession = .shared) async -> WhatsNew? {
        await Self.fetchForTag(tag, session: session)
    }

    private static func fetchLatestRelease(session: URLSession = .shared) async -> WhatsNew? {
        let urlString = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }
        return await Self.performRequest(url: url, session: session)
    }

    private static func performRequest(url: URL, session: URLSession = .shared) async -> WhatsNew? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return nil
            }
            return Self.parseRelease(data: data)
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
            releaseNotes: Self.cleanReleaseBody(body),
            learnMoreURL: URL(string: htmlURL)
        )
    }

    /// Cleans up GitHub release body by removing boilerplate sections
    /// and redundant headings that the sheet UI already provides.
    private static func cleanReleaseBody(_ body: String) -> String {
        let hiddenHeadings: Set = [
            "what's new",
            "installation",
            "verification",
            "new contributors",
            "full changelog",
        ]

        let lines = body.components(separatedBy: "\n")
        var result: [String] = []
        var skipping = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                let headingText = trimmed
                    .drop(while: { $0 == "#" || $0 == " " })
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                skipping = hiddenHeadings.contains(headingText)
                if !skipping {
                    result.append(line)
                }
            } else if !skipping {
                result.append(line)
            }
        }

        // Trim leading/trailing blank lines
        while result.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            result.removeFirst()
        }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            result.removeLast()
        }

        return result.joined(separator: "\n")
    }
}
