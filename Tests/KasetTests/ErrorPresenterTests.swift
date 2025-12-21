import XCTest
@testable import Kaset

/// Tests for the ErrorPresenter service.
@MainActor
final class ErrorPresenterTests: XCTestCase {
    var sut: ErrorPresenter!

    override func setUp() async throws {
        self.sut = ErrorPresenter.shared
        self.sut.dismiss()
    }

    override func tearDown() async throws {
        self.sut.dismiss()
        self.sut = nil
    }

    // MARK: - Presentation Tests

    func testPresentShowsError() {
        // Given
        let error = PresentableError(title: "Test", message: "Test message")

        // When
        self.sut.present(error)

        // Then
        XCTAssertTrue(self.sut.isShowingError)
        XCTAssertEqual(self.sut.currentError?.title, "Test")
        XCTAssertEqual(self.sut.currentError?.message, "Test message")
    }

    func testDismissClearsError() {
        // Given
        self.sut.present(PresentableError(title: "Test", message: "Test message"))

        // When
        self.sut.dismiss()

        // Then
        XCTAssertFalse(self.sut.isShowingError)
        XCTAssertNil(self.sut.currentError)
    }

    // MARK: - YTMusicError Conversion

    func testPresentNotAuthenticatedError() {
        // When
        self.sut.present(YTMusicError.notAuthenticated)

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Not Signed In")
    }

    func testPresentAuthExpiredError() {
        // When
        self.sut.present(YTMusicError.authExpired)

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Session Expired")
    }

    func testPresentNetworkError() {
        // Given
        let urlError = URLError(.notConnectedToInternet)

        // When
        self.sut.present(YTMusicError.networkError(underlying: urlError))

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Connection Error")
    }

    func testPresentAPIError() {
        // When
        self.sut.present(YTMusicError.apiError(message: "Server error", code: 500))

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Server Error")
    }

    func testPresentParseError() {
        // When
        self.sut.present(YTMusicError.parseError(message: "Invalid JSON"))

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Data Error")
    }

    func testPresentUnknownError() {
        // When
        self.sut.present(YTMusicError.unknown(message: "Something went wrong"))

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Error")
        XCTAssertEqual(self.sut.currentError?.message, "Something went wrong")
    }

    // MARK: - Retry Action Tests

    func testRetryInvokesAction() async {
        // Given
        let expectation = XCTestExpectation(description: "Retry action called")
        let error = PresentableError(
            title: "Test",
            message: "Test",
            retryAction: { expectation.fulfill() }
        )
        self.sut.present(error)

        // When
        await self.sut.retry()

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(self.sut.isShowingError)
    }

    func testRetryWithoutActionDismisses() async {
        // Given
        let error = PresentableError(title: "Test", message: "Test", retryAction: nil)
        self.sut.present(error)

        // When
        await self.sut.retry()

        // Then
        XCTAssertFalse(self.sut.isShowingError)
    }

    // MARK: - Dismiss Action Tests

    func testDismissInvokesAction() {
        // Given
        let expectation = XCTestExpectation(description: "Dismiss action called")
        let error = PresentableError(
            title: "Test",
            message: "Test",
            dismissAction: { expectation.fulfill() }
        )
        self.sut.present(error)

        // When
        self.sut.dismiss()

        // Then
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Generic Error Conversion

    func testPresentURLError() {
        // Given
        let urlError = URLError(.notConnectedToInternet) as Error

        // When
        self.sut.present(urlError)

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Connection Error")
    }

    func testPresentGenericError() {
        // Given
        struct CustomError: Error {}

        // When
        self.sut.present(CustomError())

        // Then
        XCTAssertEqual(self.sut.currentError?.title, "Error")
    }
}
