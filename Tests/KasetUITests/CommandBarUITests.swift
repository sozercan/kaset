import XCTest

/// UI tests for the command bar presentation.
@MainActor
final class CommandBarUITests: KasetUITestCase {
    func testCommandBarOpensWithKeyboardShortcutAndDismissesViaOverlay() throws {
        if #unavailable(macOS 26.0) {
            throw XCTSkip("The command bar requires macOS 26.")
        }

        // The command bar requires Music mode and the macOS 26 layout.
        self.app.launchArguments += [
            "-settings.appSource", "music",
            "-settings.debug.useLegacyMacOS15UI", "NO",
        ]
        self.launchDefault()

        // A launch can leave only the menu bar; open the main window explicitly.
        self.app.activate()
        self.app.typeKey("0", modifierFlags: .command)

        let window = self.app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "Main window should exist before opening the command bar.\n\(self.app.debugDescription)"
        )

        let homeItem = self.app.buttons[TestAccessibilityID.Sidebar.homeItem].firstMatch
        XCTAssertTrue(
            homeItem.waitForExistence(timeout: 10),
            "Sidebar should be visible before opening the command bar.\n\(self.app.debugDescription)"
        )

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
