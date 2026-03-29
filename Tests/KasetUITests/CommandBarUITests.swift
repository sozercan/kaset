import XCTest

/// UI tests for the command bar presentation.
@MainActor
final class CommandBarUITests: KasetUITestCase {
    func testCommandBarOpensWithKeyboardShortcutAndDismissesViaOverlay() {
        self.launchDefault()

        let sidebar = self.app.outlineRows.firstMatch
        XCTAssertTrue(self.waitForElement(sidebar, timeout: 10), "Sidebar should be visible before opening the command bar")

        let window = self.app.windows.firstMatch
        XCTAssertTrue(self.waitForElement(window), "Main window should exist")
        window.click()

        self.app.typeKey("k", modifierFlags: .command)

        let commandBar = self.app.otherElements[TestAccessibilityID.MainWindow.commandBar].firstMatch
        XCTAssertTrue(self.waitForElement(commandBar), "Command bar should appear after pressing Cmd+K")

        let input = self.app.textFields[TestAccessibilityID.MainWindow.commandBarInput].firstMatch
        XCTAssertTrue(self.waitForElement(input), "Command bar input should be visible")

        self.app.typeText("Play jazz")
        XCTAssertEqual(input.value as? String, "Play jazz", "Command bar input should stay focused on presentation")

        let overlay = self.app.otherElements[TestAccessibilityID.MainWindow.commandBarOverlay].firstMatch
        XCTAssertTrue(self.waitForHittable(overlay), "Overlay should be hittable for outside-click dismissal")
        overlay.click()

        XCTAssertTrue(self.waitForElementToDisappear(commandBar), "Command bar should dismiss after clicking the overlay")
    }
}
