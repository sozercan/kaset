// AccountsListParserTests.swift
// KasetTests
//
// Tests for AccountsListParser using Swift Testing framework.

import Testing

@testable import Kaset

// MARK: - AccountsListParserTests

@Suite
struct AccountsListParserTests {
    // MARK: - Empty/Invalid Response Tests

    @Test func parsesEmptyResponse() {
        let json: [String: Any] = [:]
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.isEmpty)
        #expect(result.googleEmail == nil)
        #expect(result.selectedAccount == nil)
        #expect(result.hasMultipleAccounts == false)
    }

    @Test func parsesResponseWithMissingActions() {
        let json: [String: Any] = ["someOtherKey": "value"]
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.isEmpty)
        #expect(result.googleEmail == nil)
    }

    @Test func parsesResponseWithEmptyActions() {
        let json: [String: Any] = ["actions": []]
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.isEmpty)
    }

    // MARK: - Single Account Tests

    @Test func parsesSingleAccount() {
        let json = MockAccountsListData.singleAccountResponse
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.count == 1)

        let account = result.accounts[0]
        #expect(account.name == "Test User")
        #expect(account.handle == "@testuser")
        #expect(account.isPrimary == true)
        #expect(account.brandId == nil)
        #expect(account.id == "primary")
        #expect(account.isSelected == true)
        #expect(account.thumbnailURL?.absoluteString == "https://example.com/avatar.jpg")
    }

    @Test func parsesSingleBrandAccount() {
        let json = MockAccountsListData.singleBrandAccountResponse
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.count == 1)

        let account = result.accounts[0]
        #expect(account.name == "Brand Account")
        #expect(account.handle == "@brandaccount")
        #expect(account.isPrimary == false)
        #expect(account.brandId == "123456789012345678901")
        #expect(account.id == "123456789012345678901")
        #expect(account.isSelected == false)
    }

    // MARK: - Multiple Accounts Tests

    @Test func parsesMultipleAccounts() {
        let json = MockAccountsListData.multipleAccountsResponse
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.count == 3)
        #expect(result.hasMultipleAccounts == true)

        // Verify primary account
        let primaryAccount = result.accounts.first { $0.isPrimary }
        #expect(primaryAccount != nil)
        #expect(primaryAccount?.name == "Test User")
        #expect(primaryAccount?.id == "primary")

        // Verify brand accounts
        let brandAccounts = result.accounts.filter { !$0.isPrimary }
        #expect(brandAccounts.count == 2)
    }

    @Test func identifiesSelectedAccount() {
        let json = MockAccountsListData.multipleAccountsResponse
        let result = AccountsListParser.parse(json)

        let selected = result.selectedAccount
        #expect(selected != nil)
        #expect(selected?.name == "Test User")
        #expect(selected?.isSelected == true)
    }

    // MARK: - Email Extraction Tests

    @Test func extractsGoogleEmail() {
        let json = MockAccountsListData.singleAccountResponse
        let result = AccountsListParser.parse(json)

        #expect(result.googleEmail == "test@example.com")
    }

    @Test func handlesMissingEmailInHeader() {
        let json = MockAccountsListData.responseWithoutEmail
        let result = AccountsListParser.parse(json)

        #expect(result.googleEmail == nil)
        #expect(result.accounts.count == 1)
    }

    // MARK: - Missing Fields Tests

    @Test func handlesMissingHandle() {
        let json = MockAccountsListData.accountWithoutHandle
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.count == 1)

        let account = result.accounts[0]
        #expect(account.name == "No Handle User")
        #expect(account.handle == nil)
    }

    @Test func handlesMissingThumbnail() {
        let json = MockAccountsListData.accountWithoutThumbnail
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.count == 1)
        #expect(result.accounts[0].thumbnailURL == nil)
    }

    @Test func skipsAccountWithMissingName() {
        let json = MockAccountsListData.accountWithoutName
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.isEmpty)
    }

    // MARK: - Account Type Identification Tests

    @Test func identifiesPrimaryAccount() {
        let json = MockAccountsListData.singleAccountResponse
        let result = AccountsListParser.parse(json)

        let account = result.accounts[0]
        #expect(account.isPrimary == true)
        #expect(account.brandId == nil)
        #expect(account.typeLabel == "Personal")
    }

    @Test func identifiesBrandAccount() {
        let json = MockAccountsListData.singleBrandAccountResponse
        let result = AccountsListParser.parse(json)

        let account = result.accounts[0]
        #expect(account.isPrimary == false)
        #expect(account.brandId != nil)
        #expect(account.typeLabel == "Brand")
    }

    // MARK: - Default Values Tests

    @Test func defaultsIsSelectedToFalse() {
        let json = MockAccountsListData.accountWithoutIsSelected
        let result = AccountsListParser.parse(json)

        #expect(result.accounts.count == 1)
        #expect(result.accounts[0].isSelected == false)
    }
}

// MARK: - MockAccountsListData

enum MockAccountsListData {
    // MARK: - Single Account Responses

    static var singleAccountResponse: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [primaryAccountItem(isSelected: true)]
            )]
        )
    }

    static var singleBrandAccountResponse: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [brandAccountItem(
                    name: "Brand Account",
                    handle: "@brandaccount",
                    brandId: "123456789012345678901",
                    isSelected: false
                )]
            )]
        )
    }

    // MARK: - Multiple Accounts Response

    static var multipleAccountsResponse: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [
                    primaryAccountItem(isSelected: true),
                    brandAccountItem(
                        name: "Brand Channel One",
                        handle: "@brandone",
                        brandId: "111111111111111111111",
                        isSelected: false
                    ),
                    brandAccountItem(
                        name: "Brand Channel Two",
                        handle: "@brandtwo",
                        brandId: "222222222222222222222",
                        isSelected: false
                    ),
                ]
            )]
        )
    }

    // MARK: - Missing Fields Responses

    static var responseWithoutEmail: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: nil,
                accounts: [primaryAccountItem(isSelected: true)]
            )]
        )
    }

    static var accountWithoutHandle: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [accountItem(
                    name: "No Handle User",
                    handle: nil,
                    brandId: nil,
                    thumbnailURL: "https://example.com/avatar.jpg",
                    isSelected: true
                )]
            )]
        )
    }

    static var accountWithoutThumbnail: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [accountItem(
                    name: "No Thumbnail User",
                    handle: "@nothumbnail",
                    brandId: nil,
                    thumbnailURL: nil,
                    isSelected: true
                )]
            )]
        )
    }

    static var accountWithoutName: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [[
                    "accountItem": [
                        "channelHandle": runsText("@noname"),
                        "isSelected": true,
                    ] as [String: Any],
                ]]
            )]
        )
    }

    static var accountWithoutIsSelected: [String: Any] {
        wrapInResponse(
            sections: [accountSection(
                email: "test@example.com",
                accounts: [[
                    "accountItem": [
                        "accountName": runsText("Unselected User"),
                        "channelHandle": runsText("@unselected"),
                    ] as [String: Any],
                ]]
            )]
        )
    }

    // MARK: - Helper Methods

    private static func wrapInResponse(sections: [[String: Any]]) -> [String: Any] {
        [
            "actions": [
                [
                    "getMultiPageMenuAction": [
                        "menu": [
                            "multiPageMenuRenderer": [
                                "sections": sections,
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func accountSection(email: String?, accounts: [[String: Any]]) -> [String: Any] {
        var header: [String: Any] = [:]
        if let email {
            header["googleAccountHeaderRenderer"] = [
                "email": Self.runsText(email),
            ]
        }

        return [
            "accountSectionListRenderer": [
                "header": header,
                "contents": [
                    [
                        "accountItemSectionRenderer": [
                            "contents": accounts,
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func primaryAccountItem(isSelected: Bool) -> [String: Any] {
        self.accountItem(
            name: "Test User",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: "https://example.com/avatar.jpg",
            isSelected: isSelected
        )
    }

    private static func brandAccountItem(
        name: String,
        handle: String,
        brandId: String,
        isSelected: Bool
    ) -> [String: Any] {
        self.accountItem(
            name: name,
            handle: handle,
            brandId: brandId,
            thumbnailURL: "https://example.com/brand-avatar.jpg",
            isSelected: isSelected
        )
    }

    private static func accountItem(
        name: String,
        handle: String?,
        brandId: String?,
        thumbnailURL: String?,
        isSelected: Bool
    ) -> [String: Any] {
        var item: [String: Any] = [
            "accountName": Self.runsText(name),
            "isSelected": isSelected,
        ]

        if let handle {
            item["channelHandle"] = Self.runsText(handle)
        }

        if let thumbnailURL {
            item["accountPhoto"] = [
                "thumbnails": [
                    ["url": thumbnailURL, "width": 88, "height": 88],
                ],
            ]
        }

        if let brandId {
            item["serviceEndpoint"] = [
                "selectActiveIdentityEndpoint": [
                    "supportedTokens": [
                        [
                            "pageIdToken": [
                                "pageId": brandId,
                            ],
                        ],
                    ],
                ],
            ]
        }

        return ["accountItem": item]
    }

    private static func runsText(_ text: String) -> [String: Any] {
        ["runs": [["text": text]]]
    }
}
