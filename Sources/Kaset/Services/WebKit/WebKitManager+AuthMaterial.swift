import Foundation

extension WebKitManager {
    nonisolated struct AuthMaterial: Equatable {
        let cookieHeader: String?
        let sapisid: String?
        let totalCookieCount: Int
        let domainCookieCount: Int
    }

    nonisolated static func cookies(_ cookies: [HTTPCookie], matching domain: String) -> [HTTPCookie] {
        let normalizedDomain = domain.lowercased()
        return cookies.filter { cookie in
            let cookieDomain = cookie.domain.lowercased()
            if cookieDomain == normalizedDomain {
                return true
            }
            if cookieDomain.hasPrefix(".") {
                let withoutDot = String(cookieDomain.dropFirst())
                return normalizedDomain == withoutDot || normalizedDomain.hasSuffix("." + withoutDot)
            }
            if normalizedDomain.hasSuffix("." + cookieDomain) {
                return true
            }
            return false
        }
    }

    nonisolated static func authMaterial(from cookies: [HTTPCookie], domain: String, now: Date = Date()) -> AuthMaterial {
        let domainCookies = Self.cookies(cookies, matching: domain)
        let cookieHeader = domainCookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: domainCookies)["Cookie"]

        let secureCookie = domainCookies.first { $0.name == Self.authCookieName }
        let fallbackCookie = domainCookies.first { $0.name == Self.fallbackAuthCookieName }
        let authCookie = secureCookie ?? fallbackCookie
        let sapisid: String? = if let authCookie {
            if let expiresDate = authCookie.expiresDate, expiresDate < now {
                nil
            } else {
                authCookie.value
            }
        } else {
            nil
        }

        return AuthMaterial(
            cookieHeader: cookieHeader,
            sapisid: sapisid,
            totalCookieCount: cookies.count,
            domainCookieCount: domainCookies.count
        )
    }

    func authMaterial(for domain: String) async -> AuthMaterial {
        let cookies = await self.getAllCookies()
        return Self.authMaterial(from: cookies, domain: domain)
    }
}
