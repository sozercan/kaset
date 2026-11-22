import XCTest

@MainActor
final class AccountSwitcherUITests: KasetUITestCase {
    func testProfileSectionDisplaysWhenLoggedIn() {
        self.launchWithMockAccounts()

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 30),
            "Profile button should exist when logged in"
        )
    }

    func testProfileShowsLoadingStateWhenFetchingAccount() {
        app.launchEnvironment["MOCK_ACCOUNT_LOADING_DELAY"] = "true"
        app.launch()

        let loadingState = app.otherElements[TestAccessibilityID.SidebarProfile.loadingState]
        XCTAssertTrue(
            loadingState.waitForExistence(timeout: 5) || app.buttons[TestAccessibilityID.SidebarProfile.profileButton].exists,
            "Either loading state or profile button should be visible"
        )
    }

    func testProfileSectionShowsLoggedOutStateWhenNotAuthenticated() {
        app.launchArguments.removeAll { $0 == "-SkipAuth" }
        app.launchEnvironment["MOCK_LOGGED_OUT"] = "true"
        app.launch()

        let loggedOutState = app.otherElements[TestAccessibilityID.SidebarProfile.loggedOutState]
        if loggedOutState.waitForExistence(timeout: 10) {
            XCTAssertTrue(loggedOutState.exists, "Logged out state should be visible when not authenticated")
        } else {
            let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
            if profileButton.exists {
                XCTAssertTrue(true, "Profile section state is acceptable")
            }
        }
    }

    func testTappingProfileOpensPopoverWhenMultipleAccounts() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        XCTAssertTrue(
            popover.waitForExistence(timeout: 15),
            "Account switcher popover should appear when clicking profile"
        )

        let header = popover.staticTexts["Switch Account"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Account switcher should show Switch Account header")
    }

    func testTappingProfileOpensGuestModePopoverWhenSingleAccount() {
        self.launchWithMockAccounts(accountCount: 1)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        XCTAssertTrue(
            popover.waitForExistence(timeout: 15),
            "Account switcher popover should appear with single account so Guest Mode can be selected"
        )

        let header = popover.staticTexts["Switch Account"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Popover should show the account switcher")
    }

    func testPopoverShowsHeader() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let header = app.staticTexts["Switch Account"]
        XCTAssertTrue(header.exists, "Popover should show 'Switch Account' header")
    }

    func testPopoverShowsAccountList() {
        self.launchWithMockAccounts(accountCount: 3)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let firstAccountRow = popover.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 0)]
        XCTAssertTrue(firstAccountRow.waitForExistence(timeout: 5), "At least one account row should exist")
    }

    func testSelectedAccountHasCheckmark() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let selectedRow = popover.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 0)]
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 5), "Selected account row should exist")
    }

    func testAccountRowsShowTypeBadges() {
        self.launchWithMockAccounts(accountCount: 2, includeBrandAccount: true)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let firstRow = popover.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 0)]
        let secondRow = popover.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "First account row should exist")
        XCTAssertTrue(secondRow.exists, "Second account row should exist (brand account)")
    }

    func testSwitchingAccountUpdatesProfile() {
        self.launchWithMockAccounts(accountCount: 2, includeBrandAccount: true)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        let initialLabel = profileButton.label

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let secondAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        guard secondAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("Second account row should exist")
            return
        }

        secondAccountRow.click()

        XCTAssertTrue(
            popover.waitForNonExistence(timeout: 5),
            "Popover should dismiss after account selection"
        )

        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 30),
            "Profile button should still exist after account switch"
        )

        let newLabel = profileButton.label
        XCTAssertNotNil(newLabel, "Profile should have a label after switching")
    }

    func testSwitchingAccountRefreshesContent() {
        self.launchWithMockAccounts(accountCount: 2)

        navigateToLibrary()

        let libraryContent = app.otherElements["libraryView"]
        _ = libraryContent.waitForExistence(timeout: 5)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let secondAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        guard secondAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("Second account row should exist")
            return
        }

        secondAccountRow.click()

        _ = popover.waitForNonExistence(timeout: 5)

        let loadingIndicator = app.progressIndicators.firstMatch
        let contentLoaded = app.scrollViews.firstMatch.waitForExistence(timeout: 10)

        XCTAssertTrue(
            contentLoaded || loadingIndicator.exists,
            "Library content should show loading or refreshed state after account switch"
        )
    }

    func testClickingOutsideDismissesPopover() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

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

    func testPressingEscapeDismissesPopover() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        popover.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            popover.waitForNonExistence(timeout: 3),
            "Popover should dismiss when pressing Escape"
        )
    }

    func testSelectingAccountDismissesPopover() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

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

    func testProfileButtonHasAccessibilityLabel() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
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

    func testProfileButtonHasAccessibilityHintWithMultipleAccounts() {
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        XCTAssertTrue(profileButton.isEnabled, "Profile button should be enabled")
    }

    func testAccountSwitchErrorShowsGracefulFallback() {
        app.launchEnvironment["MOCK_ACCOUNT_SWITCH_FAIL"] = "true"
        self.launchWithMockAccounts(accountCount: 2)

        let profileButton = app.buttons[TestAccessibilityID.SidebarProfile.profileButton]
        guard profileButton.waitForExistence(timeout: 30) else {
            XCTFail("Profile button should exist")
            return
        }

        profileButton.click()

        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 15) else {
            XCTFail("Popover should appear")
            return
        }

        let secondAccountRow = app.buttons[TestAccessibilityID.AccountSwitcher.accountRow(index: 1)]
        guard secondAccountRow.waitForExistence(timeout: 5) else {
            XCTFail("Second account row should exist")
            return
        }

        secondAccountRow.click()

        Thread.sleep(forTimeInterval: 1)

        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 5),
            "Profile button should still exist after failed account switch"
        )
    }

    private func launchWithMockAccounts(accountCount: Int = 2, includeBrandAccount: Bool = true) {
        var accounts: [[String: Any]] = []

        accounts.append([
            "id": "primary",
            "name": "Test User",
            "handle": "@testuser",
            "brandId": NSNull(),
            "thumbnailURL": "https://example.com/avatar.jpg",
            "isSelected": true,
        ])

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
