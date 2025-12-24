import Foundation
import Testing
@testable import Kaset

/// Extended tests for YTMusicError.
@Suite("YTMusicError")
struct YTMusicErrorTests {
    // MARK: - Error Description Tests

    @Test("authExpired has correct description")
    func authExpiredDescription() {
        let error = YTMusicError.authExpired
        #expect(error.errorDescription == "Your session has expired. Please sign in again.")
    }

    @Test("notAuthenticated has correct description")
    func notAuthenticatedDescription() {
        let error = YTMusicError.notAuthenticated
        #expect(error.errorDescription == "You're not signed in. Please sign in to continue.")
    }

    @Test("networkError contains 'Network error'")
    func networkErrorDescription() {
        let underlying = URLError(.notConnectedToInternet)
        let error = YTMusicError.networkError(underlying: underlying)
        #expect(error.errorDescription?.contains("Network error") == true)
    }

    @Test("parseError includes message")
    func parseErrorDescription() {
        let error = YTMusicError.parseError(message: "Invalid JSON")
        #expect(error.errorDescription == "Failed to parse response: Invalid JSON")
    }

    @Test("apiError with code includes code in description")
    func apiErrorWithCodeDescription() {
        let error = YTMusicError.apiError(message: "Rate limited", code: 429)
        #expect(error.errorDescription == "API error (429): Rate limited")
    }

    @Test("apiError without code excludes code from description")
    func apiErrorWithoutCodeDescription() {
        let error = YTMusicError.apiError(message: "Something went wrong", code: nil)
        #expect(error.errorDescription == "API error: Something went wrong")
    }

    @Test("playbackError includes message")
    func playbackErrorDescription() {
        let error = YTMusicError.playbackError(message: "Content not available")
        #expect(error.errorDescription == "Playback error: Content not available")
    }

    @Test("unknown error uses message as description")
    func unknownErrorDescription() {
        let error = YTMusicError.unknown(message: "An unexpected error occurred")
        #expect(error.errorDescription == "An unexpected error occurred")
    }

    // MARK: - Recovery Suggestion Tests

    @Test("authExpired suggests signing in")
    func authExpiredRecoverySuggestion() {
        let error = YTMusicError.authExpired
        #expect(error.recoverySuggestion == "Sign in to your YouTube Music account.")
    }

    @Test("notAuthenticated suggests signing in")
    func notAuthenticatedRecoverySuggestion() {
        let error = YTMusicError.notAuthenticated
        #expect(error.recoverySuggestion == "Sign in to your YouTube Music account.")
    }

    @Test("networkError suggests checking connection")
    func networkErrorRecoverySuggestion() {
        let error = YTMusicError.networkError(underlying: URLError(.timedOut))
        #expect(error.recoverySuggestion == "Check your internet connection and try again.")
    }

    @Test("parseError suggests trying again")
    func parseErrorRecoverySuggestion() {
        let error = YTMusicError.parseError(message: "Bad data")
        #expect(error.recoverySuggestion == "Try again. If the problem persists, the service may be temporarily unavailable.")
    }

    @Test("apiError suggests trying again")
    func apiErrorRecoverySuggestion() {
        let error = YTMusicError.apiError(message: "Error", code: 500)
        #expect(error.recoverySuggestion == "Try again. If the problem persists, the service may be temporarily unavailable.")
    }

    @Test("playbackError suggests different track")
    func playbackErrorRecoverySuggestion() {
        let error = YTMusicError.playbackError(message: "Error")
        #expect(error.recoverySuggestion == "Try playing a different track.")
    }

    @Test("unknown suggests trying later")
    func unknownErrorRecoverySuggestion() {
        let error = YTMusicError.unknown(message: "Error")
        #expect(error.recoverySuggestion == "Try again later.")
    }

    // MARK: - Requires Reauth Tests

    @Test(
        "Auth errors require reauth",
        arguments: [
            YTMusicError.authExpired,
            YTMusicError.notAuthenticated,
        ]
    )
    func authErrorsRequireReauth(error: YTMusicError) {
        #expect(error.requiresReauth)
    }

    @Test("networkError does not require reauth")
    func networkErrorDoesNotRequireReauth() {
        let error = YTMusicError.networkError(underlying: URLError(.timedOut))
        #expect(!error.requiresReauth)
    }

    @Test("parseError does not require reauth")
    func parseErrorDoesNotRequireReauth() {
        #expect(!YTMusicError.parseError(message: "Error").requiresReauth)
    }

    @Test("apiError does not require reauth")
    func apiErrorDoesNotRequireReauth() {
        #expect(!YTMusicError.apiError(message: "Error", code: 500).requiresReauth)
    }

    @Test("playbackError does not require reauth")
    func playbackErrorDoesNotRequireReauth() {
        #expect(!YTMusicError.playbackError(message: "Error").requiresReauth)
    }

    @Test("unknown does not require reauth")
    func unknownErrorDoesNotRequireReauth() {
        #expect(!YTMusicError.unknown(message: "Error").requiresReauth)
    }

    // MARK: - Debug Description Tests

    @Test("networkError debug description contains error type")
    func networkErrorDebugDescription() {
        let underlying = URLError(.notConnectedToInternet)
        let error = YTMusicError.networkError(underlying: underlying)
        let debugDesc = error.debugDescription
        #expect(debugDesc.contains("YTMusicError.networkError"))
    }

    @Test("Non-network error debug description matches error description")
    func nonNetworkErrorDebugDescription() {
        let error = YTMusicError.authExpired
        #expect(error.debugDescription == error.errorDescription)
    }

    @Test("parseError debug description matches error description")
    func parseErrorDebugDescription() {
        let error = YTMusicError.parseError(message: "Bad JSON")
        #expect(error.debugDescription == "Failed to parse response: Bad JSON")
    }
}
