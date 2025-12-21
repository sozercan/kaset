import XCTest

/// UI tests that verify the app launches correctly.
final class AppLaunchUITests: KasetUITestCase {
    // MARK: - App Launch

    func testAppLaunchesSuccessfully() throws {
        launchDefault()

        // App should launch and show main window
        XCTAssertGreaterThan(app.windows.count, 0, "App should have at least one window")
    }

    func testAppShowsMainWindowAfterLaunch() throws {
        launchDefault()

        // Wait for main window content
        // Should show sidebar navigation - look for the sidebar container or any sidebar item
        let sidebar = app.otherElements[TestAccessibilityID.Sidebar.container].firstMatch
        let sidebarExists = sidebar.waitForExistence(timeout: 10)
        
        // Also check for any sidebar item as a fallback
        let homeItem = app.buttons[TestAccessibilityID.Sidebar.homeItem].firstMatch
        let homeExists = homeItem.waitForExistence(timeout: 5)
        
        XCTAssertTrue(sidebarExists || homeExists, "Sidebar should be visible")
    }

    func testAppDefaultsToHomeView() throws {
        launchDefault()

        // Home is the default selected view
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 10), "Home should be the default view")
    }

    // MARK: - Window Properties

    func testWindowHasMinimumSize() throws {
        launchDefault()

        guard let window = app.windows.firstMatch.frame as CGRect? else {
            XCTFail("No window found")
            return
        }

        // Minimum size is 900x600 as per MainWindow
        XCTAssertGreaterThanOrEqual(window.width, 900, "Window width should be at least 900")
        XCTAssertGreaterThanOrEqual(window.height, 600, "Window height should be at least 600")
    }

    // MARK: - UI Test Mode Verification

    func testAppRunsInUITestMode() throws {
        // This test verifies the app responds to UI test launch arguments
        app.launchArguments.append("-UITestMode")
        app.launchArguments.append("-SkipAuth")
        app.launch()

        // Should skip onboarding and go directly to main content
        let sidebarItem = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebarItem, timeout: 10), "Should skip auth and show main content")
    }

    // MARK: - Mock Data Loading

    func testAppAcceptsMockEnvironmentVariables() throws {
        // Configure mock home data
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

        // App should launch successfully with mock data
        let sidebar = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))
    }

    // MARK: - Keyboard Shortcuts

    func testKeyboardShortcutNavigation() throws {
        launchDefault()

        // Wait for app to be ready
        let sidebar = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))

        // Test Cmd+1 for Home (common macOS convention)
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Test Cmd+2 for Search
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
    }
}
