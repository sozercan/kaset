import Foundation

/// Centralized accessibility identifiers for UI testing.
/// Using an enum namespace prevents typos and enables autocomplete.
enum AccessibilityID {
    // MARK: - Sidebar

    enum Sidebar {
        static let container = "sidebar"
        static let searchItem = "sidebar.search"
        static let homeItem = "sidebar.home"
        static let exploreItem = "sidebar.explore"
        static let chartsItem = "sidebar.charts"
        static let moodsAndGenresItem = "sidebar.moodsAndGenres"
        static let newReleasesItem = "sidebar.newReleases"
        static let podcastsItem = "sidebar.podcasts"
        static let likedMusicItem = "sidebar.likedMusic"
        static let libraryItem = "sidebar.library"
    }

    // MARK: - PlayerBar

    enum PlayerBar {
        static let container = "playerBar"
        static let playPauseButton = "playerBar.playPause"
        static let previousButton = "playerBar.previous"
        static let nextButton = "playerBar.next"
        static let shuffleButton = "playerBar.shuffle"
        static let repeatButton = "playerBar.repeat"
        static let likeButton = "playerBar.like"
        static let dislikeButton = "playerBar.dislike"
        static let lyricsButton = "playerBar.lyrics"
        static let queueButton = "playerBar.queue"
        static let videoButton = "playerBar.video"
        static let volumeSlider = "playerBar.volumeSlider"
        static let trackTitle = "playerBar.trackTitle"
        static let trackArtist = "playerBar.trackArtist"
        static let thumbnail = "playerBar.thumbnail"
    }

    // MARK: - Queue View

    enum Queue {
        static let container = "queueView"
        static let scrollView = "queueView.scrollView"
        static let clearButton = "queueView.clearButton"
        static let emptyState = "queueView.emptyState"
        static let refineButton = "queueView.refineButton"
        static let suggestionButton = "queueView.suggestionButton"

        static func row(index: Int) -> String {
            "queueView.row.\(index)"
        }
    }

    // MARK: - HomeView

    enum Home {
        static let container = "homeView"
        static let scrollView = "homeView.scrollView"
        static let loadingIndicator = "homeView.loading"
        static let errorView = "homeView.error"

        static func section(index: Int) -> String {
            "homeView.section.\(index)"
        }

        static func sectionTitle(index: Int) -> String {
            "homeView.section.\(index).title"
        }

        static func item(sectionIndex: Int, itemIndex: Int) -> String {
            "homeView.section.\(sectionIndex).item.\(itemIndex)"
        }
    }

    // MARK: - SearchView

    enum Search {
        static let container = "searchView"
        static let searchField = "searchView.searchField"
        static let clearButton = "searchView.clearButton"
        static let suggestionsContainer = "searchView.suggestions"
        static let resultsContainer = "searchView.results"
        static let emptyState = "searchView.emptyState"
        static let noResults = "searchView.noResults"
        static let loadingIndicator = "searchView.loading"

        static func suggestion(index: Int) -> String {
            "searchView.suggestion.\(index)"
        }

        static func filterChip(_ filter: String) -> String {
            "searchView.filter.\(filter)"
        }

        static func resultRow(index: Int) -> String {
            "searchView.result.\(index)"
        }
    }

    // MARK: - LibraryView

    enum Library {
        static let container = "libraryView"
        static let scrollView = "libraryView.scrollView"
        static let loadingIndicator = "libraryView.loading"
        static let emptyState = "libraryView.emptyState"

        static func playlistRow(index: Int) -> String {
            "libraryView.playlist.\(index)"
        }
    }

    // MARK: - PlaylistDetailView

    enum PlaylistDetail {
        static let container = "playlistDetailView"
        static let header = "playlistDetailView.header"
        static let playButton = "playlistDetailView.playButton"
        static let shuffleButton = "playlistDetailView.shuffleButton"
        static let tracksList = "playlistDetailView.tracksList"
        static let loadingIndicator = "playlistDetailView.loading"

        static func trackRow(index: Int) -> String {
            "playlistDetailView.track.\(index)"
        }
    }

    // MARK: - OnboardingView

    enum Onboarding {
        static let container = "onboardingView"
        static let signInButton = "onboardingView.signInButton"
    }

    // MARK: - Main Window

    enum MainWindow {
        static let container = "mainWindow"
        static let initializingView = "mainWindow.initializing"
        static let aiButton = "mainWindow.aiButton"
    }

    // MARK: - Explore View

    enum Explore {
        static let container = "exploreView"
        static let scrollView = "exploreView.scrollView"
        static let loadingIndicator = "exploreView.loading"
    }

    // MARK: - Liked Music View

    enum LikedMusic {
        static let container = "likedMusicView"
        static let scrollView = "likedMusicView.scrollView"
        static let loadingIndicator = "likedMusicView.loading"
        static let emptyState = "likedMusicView.emptyState"

        static func songRow(index: Int) -> String {
            "likedMusicView.song.\(index)"
        }
    }

    // MARK: - Video Window

    enum VideoWindow {
        static let container = "videoWindow"
        static let videoContent = "videoWindow.content"
    }
}
