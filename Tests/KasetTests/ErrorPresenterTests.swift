import Foundation
import Testing
@testable import Kaset

/// Helper class to track action calls in a thread-safe way.
private final class ActionTracker: @unchecked Sendable {
    var called = false
}

/// Tests for the ErrorPresenter service.
@Suite(.serialized)
@MainActor
struct ErrorPresenterTests {
    var sut: ErrorPresenter

    init() {
        self.sut = ErrorPresenter.shared
        self.sut.dismiss()
    }

    // MARK: - Presentation Tests

    @Test("Present shows error")
    func presentShowsError() {
        let error = PresentableError(title: "Test", message: "Test message")

        sut.present(error)

        #expect(sut.isShowingError == true)
        #expect(sut.currentError?.title == "Test")
        #expect(sut.currentError?.message == "Test message")
    }

    @Test("Dismiss clears error")
    func dismissClearsError() {
        sut.present(PresentableError(title: "Test", message: "Test message"))

        sut.dismiss()

        #expect(sut.isShowingError == false)
        #expect(sut.currentError == nil)
    }

    // MARK: - YTMusicError Conversion

    @Test("Present notAuthenticated error")
    func presentNotAuthenticatedError() {
        sut.present(YTMusicError.notAuthenticated)
        #expect(sut.currentError?.title == "Not Signed In")
    }

    @Test("Present authExpired error")
    func presentAuthExpiredError() {
        sut.present(YTMusicError.authExpired)
        #expect(sut.currentError?.title == "Session Expired")
    }

    @Test("Present network error")
    func presentNetworkError() {
        let urlError = URLError(.notConnectedToInternet)
        sut.present(YTMusicError.networkError(underlying: urlError))
        #expect(sut.currentError?.title == "Connection Error")
    }

    @Test("Present API error")
    func presentAPIError() {
        sut.present(YTMusicError.apiError(message: "Server error", code: 500))
        #expect(sut.currentError?.title == "Server Error")
    }

    @Test("Present parse error")
    func presentParseError() {
        sut.present(YTMusicError.parseError(message: "Invalid JSON"))
        #expect(sut.currentError?.title == "Data Error")
    }

    @Test("Present unknown error")
    func presentUnknownError() {
        sut.present(YTMusicError.unknown(message: "Something went wrong"))
        #expect(sut.currentError?.title == "Error")
        #expect(sut.currentError?.message == "Something went wrong")
    }

    // MARK: - Retry Action Tests

    @Test("Retry invokes action and dismisses")
    func retryInvokesAction() async {
        let tracker = ActionTracker()
        let error = PresentableError(
            title: "Test",
            message: "Test",
            retryAction: { tracker.called = true }
        )
        sut.present(error)

        await sut.retry()

        #expect(tracker.called == true)
        #expect(sut.isShowingError == false)
    }

    @Test("Retry without action dismisses")
    func retryWithoutActionDismisses() async {
        let error = PresentableError(title: "Test", message: "Test", retryAction: nil)
        sut.present(error)

        await sut.retry()

        #expect(sut.isShowingError == false)
    }

    // MARK: - Dismiss Action Tests

    @Test("Dismiss invokes action")
    func dismissInvokesAction() {
        let tracker = ActionTracker()
        let error = PresentableError(
            title: "Test",
            message: "Test",
            dismissAction: { tracker.called = true }
        )
        sut.present(error)

        sut.dismiss()

        #expect(tracker.called == true)
    }

    // MARK: - Generic Error Conversion

    @Test("Present URLError")
    func presentURLError() {
        let urlError = URLError(.notConnectedToInternet) as Error
        sut.present(urlError)
        #expect(sut.currentError?.title == "Connection Error")
    }

    @Test("Present generic error")
    func presentGenericError() {
        struct CustomError: Error {}
        sut.present(CustomError())
        #expect(sut.currentError?.title == "Error")
    }
}
