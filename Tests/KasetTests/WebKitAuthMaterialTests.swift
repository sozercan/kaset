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
