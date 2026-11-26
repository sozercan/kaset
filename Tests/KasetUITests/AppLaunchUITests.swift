import XCTest

@MainActor
final class AppLaunchUITests: KasetUITestCase {
    func testAppLaunchesSuccessfully() {
        launchDefault()

        XCTAssertGreaterThan(app.windows.count, 0, "App should have at least one window")
    }

    func testAppShowsMainWindowAfterLaunch() {
        launchDefault()

        let sidebar = app.otherElements[TestAccessibilityID.Sidebar.container].firstMatch
        let sidebarExists = sidebar.waitForExistence(timeout: 10)

        let homeItem = app.buttons[TestAccessibilityID.Sidebar.homeItem].firstMatch
        let homeExists = homeItem.waitForExistence(timeout: 5)

        XCTAssertTrue(sidebarExists || homeExists, "Sidebar should be visible")
    }

    func testAppDefaultsToHomeView() {
        launchDefault()

        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 10), "Home should be the default view")
    }

    func testWindowHasMinimumSize() {
        launchDefault()

        guard let window = app.windows.firstMatch.frame as CGRect? else {
            XCTFail("No window found")
            return
        }

        XCTAssertGreaterThanOrEqual(window.width, 900, "Window width should be at least 900")
        XCTAssertGreaterThanOrEqual(window.height, 600, "Window height should be at least 600")
    }

    func testAppRunsInUITestMode() {
        app.launchArguments.append("-UITestMode")
        app.launchArguments.append("-SkipAuth")
        app.launch()

        let sidebarItem = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebarItem, timeout: 10), "Should skip auth and show main content")
    }

    func testAppAcceptsMockEnvironmentVariables() {
        app.launchArguments.append("-UITestMode")
        app.launchArguments.append("-SkipAuth")

        let mockSections = [
            ["id": "test-section", "title": "Test Section", "items": []],
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: mockSections),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            app.launchEnvironment["MOCK_HOME_SECTIONS"] = jsonString
        }

        app.launch()

        let sidebar = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))
    }

    func testKeyboardShortcutNavigation() {
        launchDefault()

        let sidebar = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))

        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
    }
}
