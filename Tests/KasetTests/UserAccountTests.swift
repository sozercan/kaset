// UserAccountTests.swift
// KasetTests
//
// Tests for UserAccount model using Swift Testing framework.

import Testing

@testable import Kaset

// MARK: - UserAccountTests

@Suite
struct UserAccountTests {
    // MARK: - Primary Account Tests

    @Test func primaryAccountHasNilBrandId() {
        let account = MockUserAccountData.primaryAccount

        #expect(account.brandId == nil)
        #expect(account.isPrimary == true)
        #expect(account.id == "primary")
        #expect(account.typeLabel == "Personal")
    }

    @Test func primaryAccountName() {
        let account = MockUserAccountData.primaryAccount

        #expect(account.name == "Test User")
    }

    @Test func primaryAccountHandle() {
        let account = MockUserAccountData.primaryAccount

        #expect(account.handle == "@testuser")
    }

    // MARK: - Brand Account Tests

    @Test func brandAccountHasBrandId() {
        let account = MockUserAccountData.brandAccount

        #expect(account.brandId == "123456789012345678901")
        #expect(account.isPrimary == false)
        #expect(account.id == "123456789012345678901")
        #expect(account.typeLabel == "Brand")
    }

    @Test func brandAccountName() {
        let account = MockUserAccountData.brandAccount

        #expect(account.name == "Brand Account")
    }

    @Test func brandAccountHandle() {
        let account = MockUserAccountData.brandAccount

        #expect(account.handle == "@brandaccount")
    }

    // MARK: - Factory Method Tests

    @Test func factoryMethodCreatesPrimaryAccount() {
        let account = UserAccount.from(
            name: "Factory User",
            handle: "@factoryuser",
            brandId: nil,
            thumbnailURL: URL(string: "https://example.com/avatar.jpg"),
            isSelected: true
        )

        #expect(account.id == "primary")
        #expect(account.name == "Factory User")
        #expect(account.handle == "@factoryuser")
        #expect(account.brandId == nil)
        #expect(account.isPrimary == true)
        #expect(account.isSelected == true)
        #expect(account.thumbnailURL?.absoluteString == "https://example.com/avatar.jpg")
    }

    @Test func factoryMethodCreatesBrandAccount() {
        let brandId = "987654321098765432109"
        let account = UserAccount.from(
            name: "Factory Brand",
            handle: "@factorybrand",
            brandId: brandId,
            thumbnailURL: URL(string: "https://example.com/brand.jpg"),
            isSelected: false
        )

        #expect(account.id == brandId)
        #expect(account.name == "Factory Brand")
        #expect(account.handle == "@factorybrand")
        #expect(account.brandId == brandId)
        #expect(account.isPrimary == false)
        #expect(account.isSelected == false)
    }

    // MARK: - Equatable Tests

    @Test func accountEqualitySameAccounts() {
        let account1 = MockUserAccountData.primaryAccount
        let account2 = MockUserAccountData.primaryAccount

        #expect(account1 == account2)
    }

    @Test func accountEqualityDifferentAccounts() {
        let account1 = MockUserAccountData.primaryAccount
        let account2 = MockUserAccountData.brandAccount

        #expect(account1 != account2)
    }

    @Test func accountEqualityDifferentSelectionState() {
        let account1 = UserAccount.from(
            name: "Test User",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: URL(string: "https://example.com/avatar.jpg"),
            isSelected: true
        )
        let account2 = UserAccount.from(
            name: "Test User",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: URL(string: "https://example.com/avatar.jpg"),
            isSelected: false
        )

        // Accounts with different isSelected should NOT be equal
        #expect(account1 != account2)
    }

    @Test func accountEqualityDifferentNames() {
        let account1 = UserAccount.from(
            name: "User A",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false
        )
        let account2 = UserAccount.from(
            name: "User B",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false
        )

        #expect(account1 != account2)
    }

    // MARK: - Hashable Tests

    @Test func accountHashability() {
        let account1 = MockUserAccountData.primaryAccount
        let account2 = MockUserAccountData.primaryAccount

        #expect(account1.hashValue == account2.hashValue)
    }

    @Test func accountHashabilityInSet() {
        let account1 = MockUserAccountData.primaryAccount
        let account2 = MockUserAccountData.primaryAccount
        let account3 = MockUserAccountData.brandAccount

        var set = Set<UserAccount>()
        set.insert(account1)
        set.insert(account2)
        set.insert(account3)

        // account1 and account2 are equal, so set should have 2 elements
        #expect(set.count == 2)
    }

    @Test func accountHashabilityDifferentAccounts() {
        let account1 = MockUserAccountData.primaryAccount
        let account2 = MockUserAccountData.brandAccount

        // Different accounts should (almost certainly) have different hashes
        #expect(account1.hashValue != account2.hashValue)
    }

    // MARK: - Optional Fields Tests

    @Test func accountWithNilHandle() {
        let account = UserAccount.from(
            name: "No Handle User",
            handle: nil,
            brandId: nil,
            thumbnailURL: URL(string: "https://example.com/avatar.jpg"),
            isSelected: false
        )

        #expect(account.handle == nil)
        #expect(account.name == "No Handle User")
    }

    @Test func accountWithNilThumbnail() {
        let account = UserAccount.from(
            name: "No Thumbnail User",
            handle: "@nothumbnail",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false
        )

        #expect(account.thumbnailURL == nil)
        #expect(account.name == "No Thumbnail User")
    }

    @Test func accountWithAllNilOptionals() {
        let account = UserAccount.from(
            name: "Minimal User",
            handle: nil,
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false
        )

        #expect(account.name == "Minimal User")
        #expect(account.handle == nil)
        #expect(account.brandId == nil)
        #expect(account.thumbnailURL == nil)
        #expect(account.id == "primary")
        #expect(account.isPrimary == true)
    }

    // MARK: - Selection State Tests

    @Test func selectedAccountState() {
        let selected = UserAccount.from(
            name: "Selected User",
            handle: "@selected",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )

        #expect(selected.isSelected == true)
    }

    @Test func unselectedAccountState() {
        let unselected = UserAccount.from(
            name: "Unselected User",
            handle: "@unselected",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false
        )

        #expect(unselected.isSelected == false)
    }

    // MARK: - Type Label Tests

    @Test func typeLabelForPrimaryAccount() {
        let primary = MockUserAccountData.primaryAccount

        #expect(primary.typeLabel == "Personal")
    }

    @Test func typeLabelForBrandAccount() {
        let brand = MockUserAccountData.brandAccount

        #expect(brand.typeLabel == "Brand")
    }
}

// MARK: - MockUserAccountData

enum MockUserAccountData {
    static var primaryAccount: UserAccount {
        UserAccount.from(
            name: "Test User",
            handle: "@testuser",
            brandId: nil,
            thumbnailURL: URL(string: "https://example.com/avatar.jpg"),
            isSelected: true
        )
    }

    static var brandAccount: UserAccount {
        UserAccount.from(
            name: "Brand Account",
            handle: "@brandaccount",
            brandId: "123456789012345678901",
            thumbnailURL: URL(string: "https://example.com/brand-avatar.jpg"),
            isSelected: false
        )
    }

    static var selectedBrandAccount: UserAccount {
        UserAccount.from(
            name: "Selected Brand",
            handle: "@selectedbrand",
            brandId: "999888777666555444333",
            thumbnailURL: URL(string: "https://example.com/selected-brand.jpg"),
            isSelected: true
        )
    }

    static var minimalAccount: UserAccount {
        UserAccount.from(
            name: "Minimal User",
            handle: nil,
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false
        )
    }
}
