import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct WebKitAuthMaterialTests {
    @Test("Auth material derives header and SAPISID from one snapshot")
    func authMaterialFromSnapshot() throws {
        let cookies = try [
            Self.cookie(name: "PREF", value: "test-pref", domain: ".youtube.com"),
            Self.cookie(name: "__Secure-3PAPISID", value: "mock-secure-token", domain: ".youtube.com"),
            Self.cookie(name: "SID", value: "ignored", domain: ".google.com"),
        ]

        let material = WebKitManager.authMaterial(from: cookies, domain: "youtube.com")

        #expect(material.totalCookieCount == 3)
        #expect(material.domainCookieCount == 2)
        #expect(material.cookieHeader?.contains("PREF=test-pref") == true)
        #expect(material.cookieHeader?.contains("__Secure-3PAPISID=mock-secure-token") == true)
        #expect(material.cookieHeader?.contains("SID=ignored") == false)
        #expect(material.sapisid == "mock-secure-token")
    }

    @Test("Expired secure auth cookie does not fall back to another auth cookie")
    func expiredSecureCookieDoesNotFallback() throws {
        let cookies = try [
            Self.cookie(
                name: "__Secure-3PAPISID",
                value: "expired-secure-token",
                domain: ".youtube.com",
                expires: Date(timeIntervalSince1970: 1)
            ),
            Self.cookie(name: "SAPISID", value: "fallback-token", domain: ".youtube.com"),
        ]

        let material = WebKitManager.authMaterial(
            from: cookies,
            domain: "youtube.com",
            now: Date(timeIntervalSince1970: 2)
        )

        #expect(material.cookieHeader != nil)
        #expect(material.sapisid == nil)
    }

    @Test("Domain matching includes subdomains and leading-dot domains")
    func domainMatchingIncludesSubdomains() throws {
        let cookies = try [
            Self.cookie(name: "A", value: "1", domain: ".youtube.com"),
            Self.cookie(name: "B", value: "2", domain: "youtube.com"),
            Self.cookie(name: "C", value: "3", domain: "music.youtube.com"),
            Self.cookie(name: "D", value: "4", domain: "example.com"),
        ]

        let matched = WebKitManager.cookies(cookies, matching: "music.youtube.com")
            .map(\.name)
            .sorted()

        #expect(matched == ["A", "B", "C"])
    }

    @Test("Auth cookie persistence accepts only Google and YouTube domain boundaries")
    func authCookiePersistenceDomainBoundaries() throws {
        #expect(KeychainCookieStorage.isAllowedAuthCookieDomain("youtube.com"))
        #expect(KeychainCookieStorage.isAllowedAuthCookieDomain(".youtube.com"))
        #expect(KeychainCookieStorage.isAllowedAuthCookieDomain("music.youtube.com"))
        #expect(KeychainCookieStorage.isAllowedAuthCookieDomain("accounts.google.com"))
        #expect(!KeychainCookieStorage.isAllowedAuthCookieDomain("notyoutube.com"))
        #expect(!KeychainCookieStorage.isAllowedAuthCookieDomain("evilgoogle.com"))
        #expect(!KeychainCookieStorage.isAllowedAuthCookieDomain("youtube.com.example.com"))

        let validCookie = try Self.cookie(
            name: "SID",
            value: "mock-token",
            domain: ".google.com"
        )
        let lookalikeCookie = try Self.cookie(
            name: "SID",
            value: "mock-token",
            domain: "evilgoogle.com"
        )

        #expect(KeychainCookieStorage.isAuthCookie(validCookie))
        #expect(!KeychainCookieStorage.isAuthCookie(lookalikeCookie))

        let gaiaCookie = try Self.cookie(
            name: "LSID",
            value: "mock-gaia-token",
            domain: "accounts.google.com"
        )
        #expect(!KeychainCookieStorage.isAuthCookie(gaiaCookie))
        #expect(KeychainCookieStorage.isLoginDomainCookie(gaiaCookie))
        #expect(KeychainCookieStorage.isLoginSessionCookie(gaiaCookie))
        #expect(!KeychainCookieStorage.isLoginDomainCookie(lookalikeCookie))

        let preferenceCookie = try Self.cookie(
            name: "PREF",
            value: "public-preference",
            domain: ".youtube.com"
        )
        #expect(!KeychainCookieStorage.isLoginSessionCookie(preferenceCookie))

        #expect(KeychainCookieStorage.makeArchiveResult(from: [validCookie]) == .noPrimarySession)
        #expect(CookieArchiveBackupAction.make(from: .noPrimarySession) == .invalidate)
    }

    @Test("Cookie serialization failures retain the last good archive")
    func cookieSerializationFailuresRetainLastGoodArchive() throws {
        let primaryCookie = try Self.cookie(
            name: "SAPISID",
            value: "mock-primary-session",
            domain: ".youtube.com"
        )

        let cookieFailure = KeychainCookieStorage.makeArchiveResult(
            from: [primaryCookie],
            serializeCookie: { _ in nil },
            serializeArchive: { _ in Data([0x01]) }
        )
        let archiveFailure = KeychainCookieStorage.makeArchiveResult(
            from: [primaryCookie],
            serializeCookie: { _ in Data([0x01]) },
            serializeArchive: { _ in nil }
        )

        #expect(cookieFailure == .failure)
        #expect(archiveFailure == .failure)
        #expect(CookieArchiveBackupAction.make(from: cookieFailure) == .retainExisting)
        #expect(CookieArchiveBackupAction.make(from: archiveFailure) == .retainExisting)
    }

    private static func cookie(
        name: String,
        value: String,
        domain: String,
        expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ]
        if let expires {
            properties[.expires] = expires
        }
        return try #require(HTTPCookie(properties: properties))
    }
}
