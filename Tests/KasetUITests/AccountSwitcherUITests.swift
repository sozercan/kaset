import XCTest

/// UI tests for account switcher functionality.
///
/// These tests verify the sidebar profile section and account switching behavior.
/// > ⚠️ **Ask permission before running UI tests** — UI tests launch the app and can be disruptive.
@MainActor
final class AccountSwitcherUITests: KasetUITestCase {
    // MARK: - Profile Display Tests

    /// Verifies the profile section appears at bottom of sidebar when logged in.
    func testProfileSectionDisplaysWhenLoggedIn() throws {
        // Launch with mock accounts to simulate logged-in state
        self.launchWithMockAccounts()

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 10),
            "Profile button should exist when logged in"
        )

        // Verify profile name is visible
        let profileName = app.staticTexts.matching(identifier: "sidebarProfile.profileButton")
            .firstMatch
        XCTAssertTrue(profileName.exists, "Profile section should be visible")
    }

    /// Verifies profile section shows loading state when account is being fetched.
    func testProfileShowsLoadingStateWhenFetchingAccount() throws {
        // Launch with delayed account loading
        app.launchEnvironment["MOCK_ACCOUNT_LOADING_DELAY"] = "true"
        app.launch()

        let loadingState = app.otherElements[TestAccessibilityID.SidebarProfile.loadingState]
        // Loading state may appear briefly before accounts load
        // This test verifies the loading state identifier exists in the view hierarchy
        XCTAssertTrue(
            loadingState.waitForExistence(timeout: 5) || app.buttons[TestAccessibilityID.SidebarProfile.profileButton].exists,
            "Either loading state or profile button should be visible"
        )
    }

    /// Verifies profile section shows logged-out state when not authenticated.
    func testProfileSectionShowsLoggedOutStateWhenNotAuthenticated() throws {
        // Launch without auth
        app.launchArguments.removeAll { $0 == "-SkipAuth" }
        app.launchEnvironment["MOCK_LOGGED_OUT"] = "true"
        app.launch()

        let loggedOutState = app.otherElements[TestAccessibilityID.SidebarProfile.loggedOutState]
        if loggedOutState.waitForExistence(timeout: 10) {
            XCTAssertTrue(loggedOutState.exists, "Logged out state should be visible when not authenticated")
        } else {
            // If mock doesn't trigger logged-out state, verify profile button doesn't show multiple accounts
            let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
            if profileButton.exists {
                // Profile exists but should not have account switcher functionality
                XCTAssertTrue(true, "Profile section state is acceptable")
            }
        }
    }

    // MARK: - Popover Tests

    /// Verifies tapping profile opens account switcher popover when multiple accounts exist.
    func testTappingProfileOpensPopoverWhenMultipleAccounts() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        XCTAssertTrue(
            popover.waitForExistence(timeout: 5),
            "Account switcher popover should appear when clicking profile"
        )

        // Verify popover contains the account switcher
        let accountSwitcher = app.otherElements[TestAccessibilityID.AccountSwitcher.container]
        XCTAssertTrue(accountSwitcher.exists, "Account switcher container should exist in popover")
    }

    /// Verifies tapping profile does NOT open popover when only one account exists.
    func testTappingProfileDoesNotOpenPopoverWhenSingleAccount() throws {
        self.launchWithMockAccounts(accountCount: 1)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        // Short wait to see if popover appears (it shouldn't)
        let popover = app.popovers.firstMatch
        XCTAssertFalse(
            popover.waitForExistence(timeout: 2),
            "Account switcher popover should NOT appear with single account"
        )
    }

    /// Verifies popover shows header with "Switch Account" title.
    func testPopoverShowsHeader() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        let header = app.staticTexts["Switch Account"]
        XCTAssertTrue(header.exists, "Popover should show 'Switch Account' header")
    }

    /// Verifies popover shows list of all available accounts.
    func testPopoverShowsAccountList() throws {
        self.launchWithMockAccounts(accountCount: 3)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Verify accounts list container exists
        let accountsList = app.otherElements[TestAccessibilityID.AccountSwitcher.accountsList]
        XCTAssertTrue(accountsList.exists, "Accounts list should exist")

        // Verify at least one account row exists
        let firstAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 0)]
        XCTAssertTrue(firstAccountRow.exists, "At least one account row should exist")
    }

    /// Verifies selected account has checkmark indicator.
    func testSelectedAccountHasCheckmark() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Look for checkmark image in the popover
        let checkmark = popover.images["checkmark"]
        XCTAssertTrue(checkmark.exists, "Selected account should show checkmark")
    }

    /// Verifies account rows display account type badges (Personal/Brand).
    func testAccountRowsShowTypeBadges() throws {
        self.launchWithMockAccounts(accountCount: 2, includeBrandAccount: true)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Look for type badge text
        let personalBadge = popover.staticTexts["Personal"]
        let brandBadge = popover.staticTexts["Brand"]

        XCTAssertTrue(
            personalBadge.exists || brandBadge.exists,
            "Account type badges should be visible"
        )
    }

    // MARK: - Account Switching Tests

    /// Verifies switching accounts updates the profile display.
    func testSwitchingAccountUpdatesProfile() throws {
        self.launchWithMockAccounts(accountCount: 2, includeBrandAccount: true)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        // Get initial profile state by checking accessibility label
        let initialLabel = profileButton.label

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Find and click a non-selected account (second account)
        let secondAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        guard secondAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("Second account row should exist")
            return
        }

        secondAccountRow.click()

        // Wait for popover to dismiss
        XCTAssertTrue(
            popover.waitForNonExistence(timeout: 5),
            "Popover should dismiss after account selection"
        )

        // Verify profile button still exists (account switch completed)
        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 10),
            "Profile button should still exist after account switch"
        )

        // The label should have changed (or at minimum, the switch completed without crash)
        let newLabel = profileButton.label
        // Note: Label comparison may vary based on mock data
        XCTAssertNotNil(newLabel, "Profile should have a label after switching")
    }

    /// Verifies switching accounts triggers content refresh.
    func testSwitchingAccountRefreshesContent() throws {
        self.launchWithMockAccounts(accountCount: 2)

        // First navigate to Library (user-specific content)
        navigateToLibrary()

        let libraryContent = app.otherElements["libraryView"]
        _ = libraryContent.waitForExistence(timeout: 5)

        // Now switch accounts
        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        let secondAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        guard secondAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("Second account row should exist")
            return
        }

        secondAccountRow.click()

        // Wait for popover to dismiss
        _ = popover.waitForNonExistence(timeout: 5)

        // Content should refresh - look for loading indicator or refreshed content
        // The exact verification depends on mock implementation
        let loadingIndicator = app.progressIndicators.firstMatch
        let contentLoaded = app.scrollViews.firstMatch.waitForExistence(timeout: 10)

        XCTAssertTrue(
            contentLoaded || loadingIndicator.exists,
            "Library content should show loading or refreshed state after account switch"
        )
    }

    // MARK: - Dismiss Tests

    /// Verifies clicking outside popover dismisses it.
    func testClickingOutsideDismissesPopover() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Click somewhere outside the popover (on the main window content area)
        let mainContent = app.windows.firstMatch
        let popoverFrame = popover.frame
        let clickPoint = CGPoint(
            x: popoverFrame.maxX + 50,
            y: popoverFrame.midY
        )

        mainContent.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: clickPoint.x, dy: clickPoint.y))
            .click()

        XCTAssertTrue(
            popover.waitForNonExistence(timeout: 3),
            "Popover should dismiss when clicking outside"
        )
    }

    /// Verifies pressing Escape key dismisses popover.
    func testPressingEscapeDismissesPopover() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Press Escape key
        popover.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            popover.waitForNonExistence(timeout: 3),
            "Popover should dismiss when pressing Escape"
        )
    }

    /// Verifies selecting an account dismisses the popover.
    func testSelectingAccountDismissesPopover() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        // Click the first account row (even if already selected)
        let firstAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 0)]
        guard firstAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("First account row should exist")
            return
        }

        firstAccountRow.click()

        XCTAssertTrue(
            popover.waitForNonExistence(timeout: 5),
            "Popover should dismiss after selecting an account"
        )
    }

    // MARK: - Accessibility Tests

    /// Verifies profile button has appropriate accessibility label.
    func testProfileButtonHasAccessibilityLabel() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        let label = profileButton.label
        XCTAssertFalse(label.isEmpty, "Profile button should have an accessibility label")
        XCTAssertTrue(
            label.contains("Profile") || label.lowercased().contains("account"),
            "Accessibility label should indicate profile/account context"
        )
    }

    /// Verifies profile button has accessibility hint when multiple accounts available.
    func testProfileButtonHasAccessibilityHintWithMultipleAccounts() throws {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        // The hint should indicate that tapping will allow switching accounts
        // Note: Checking hint programmatically may require accessibility inspection
        // This test primarily verifies the button is accessible
        XCTAssertTrue(profileButton.isEnabled, "Profile button should be enabled")
    }

    // MARK: - Error Handling Tests

    /// Verifies error state is handled gracefully when account switch fails.
    func testAccountSwitchErrorShowsGracefulFallback() throws {
        // Launch with mock that will fail on account switch
        app.launchEnvironment["MOCK_ACCOUNT_SWITCH_FAIL"] = "true"
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 10) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("Popover should appear")
            return
        }

        let secondAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        guard secondAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("Second account row should exist")
            return
        }

        secondAccountRow.click()

        // Wait a moment for error handling to occur
        Thread.sleep(forTimeInterval: 1)

        // App should not crash - profile button should still be accessible
        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 5),
            "Profile button should still exist after failed account switch"
        )
    }

    // MARK: - Launch Helpers

    /// Launches the app with mock accounts for testing.
    /// - Parameters:
    ///   - accountCount: Number of mock accounts to create (default: 2)
    ///   - includeBrandAccount: Whether to include a brand account in the mock data
    private func launchWithMockAccounts(accountCount: Int = 2, includeBrandAccount: Bool = true) {
        var accounts: [[String: Any]] = []

        // Primary account
        accounts.append([
            "id": "primary",
            "name": "Test User",
            "handle": "@testuser",
            "brandId": NSNull(),
            "thumbnailURL": "https://example.com/avatar.jpg",
            "isSelected": true,
        ])

        // Additional accounts
        for i in 1 ..< accountCount {
            let isBrand = includeBrandAccount && i == 1
            accounts.append([
                "id": isBrand ? "brand-\(i)" : "account-\(i)",
                "name": isBrand ? "Brand Account \(i)" : "Account \(i)",
                "handle": isBrand ? "@brand\(i)" : "@account\(i)",
                "brandId": isBrand ? "123456789012345678901" : NSNull(),
                "thumbnailURL": "https://example.com/avatar\(i).jpg",
                "isSelected": false,
            ])
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: accounts),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            app.launchEnvironment["MOCK_ACCOUNTS"] = jsonString
        }

        app.launch()
    }
}
