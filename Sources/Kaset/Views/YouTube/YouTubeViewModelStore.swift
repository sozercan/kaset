import Foundation
import Observation

/// Owns the YouTube experience's view models so they persist across
/// source toggles and sidebar navigation (parallel to MainWindow's cached
/// music view models, but grouped to keep MainWindow lean).
@MainActor
@Observable
final class YouTubeViewModelStore {
    let client: any YouTubeClientProtocol

    private(set) var home: YouTubeHomeViewModel
    private(set) var search: YouTubeSearchViewModel

    init(client: any YouTubeClientProtocol) {
        self.client = client
        self.home = YouTubeHomeViewModel(client: client)
        self.search = YouTubeSearchViewModel(client: client)
    }

    /// Resets account-scoped state after an account switch.
    func resetForAccountChange() {
        self.home = YouTubeHomeViewModel(client: self.client)
        self.search = YouTubeSearchViewModel(client: self.client)
    }
}
