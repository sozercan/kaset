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

        let input = self.app.textFields[TestAccessibilityID.MainWindow.commandBarInput].firstMatch
        XCTAssertTrue(
            input.waitForExistence(timeout: 5),
            "Command bar input should appear after pressing Cmd+K.\n\(self.app.debugDescription)"
        )

        self.app.typeText("Play jazz")
        XCTAssertEqual(
            input.value as? String,
            "Play jazz",
            "Command bar input should stay focused on presentation.\n\(self.app.debugDescription)"
        )

        // Click beside the centered command bar to exercise outside-click dismissal.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()

        XCTAssertTrue(self.waitForElementToDisappear(input), "Command bar should dismiss after clicking the overlay")
    }
}
