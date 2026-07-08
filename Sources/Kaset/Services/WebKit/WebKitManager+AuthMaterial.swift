import Foundation

// MARK: - WebKitManager Auth Material

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
            // Exact match
            if cookieDomain == normalizedDomain {
                return true
            }
            // Cookie domain with leading dot matches the domain and all subdomains
            // e.g., ".youtube.com" matches "music.youtube.com" and "youtube.com"
            if cookieDomain.hasPrefix(".") {
                let withoutDot = String(cookieDomain.dropFirst())
                return normalizedDomain == withoutDot || normalizedDomain.hasSuffix("." + withoutDot)
            }
            // Request domain is a subdomain of cookie domain
            // e.g., cookie for "youtube.com" should match "music.youtube.com"
            if normalizedDomain.hasSuffix("." + cookieDomain) {
                return true
            }
            return false
        }
    }

    nonisolated static func authMaterial(from cookies: [HTTPCookie], domain: String, now: Date = Date()) -> AuthMaterial {
        let domainCookies = Self.cookies(cookies, matching: domain)
        let cookieHeader = domainCookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: domainCookies)["Cookie"]

        // Preserve the existing secure-first semantics: if the secure auth cookie is present but expired,
        // auth is expired even if a fallback cookie also exists.
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

    /// Returns cookie/auth material for one request by enumerating the WebKit cookie store once.
    func authMaterial(for domain: String) async -> AuthMaterial {
        let cookies = await self.getAllCookies()
        return Self.authMaterial(from: cookies, domain: domain)
    }
}
