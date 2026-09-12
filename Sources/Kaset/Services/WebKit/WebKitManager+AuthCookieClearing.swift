import Foundation
import WebKit

// MARK: - AuthCookieOperationFence

struct AuthCookieOperationFence {
    private(set) var generation: UInt64 = 0

    mutating func invalidate() {
        self.generation &+= 1
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        expectedGeneration == self.generation
    }
}

// MARK: - LiveAuthCookieClearResult

struct LiveAuthCookieClearResult: Equatable {
    let didClear: Bool
    let usedCookieStoreFallback: Bool
}

// MARK: - LiveAuthCookieStoreClearer

@MainActor
enum LiveAuthCookieStoreClearer {
    struct Operations {
        let readCookies: @MainActor () async -> [HTTPCookie]
        let deleteCookie: @MainActor (HTTPCookie) async -> Void
        let removeAllCookies: @MainActor () async -> Void
    }

    static func clear(
        maximumDeletePasses: Int = 3,
        operations: Operations
    ) async -> LiveAuthCookieClearResult {
        for _ in 0 ..< max(maximumDeletePasses, 0) {
            let cookies = await operations.readCookies()
            for cookie in cookies where KeychainCookieStorage.isLoginSessionCookie(cookie) {
                await operations.deleteCookie(cookie)
            }
            let remainingCookies = await operations.readCookies()
            if !remainingCookies.contains(where: KeychainCookieStorage.isLoginSessionCookie) {
                return LiveAuthCookieClearResult(
                    didClear: true,
                    usedCookieStoreFallback: false
                )
            }
            await Task.yield()
        }

        await operations.removeAllCookies()
        let remainingCookies = await operations.readCookies()
        return LiveAuthCookieClearResult(
            didClear: !remainingCookies.contains(where: KeychainCookieStorage.isLoginSessionCookie),
            usedCookieStoreFallback: true
        )
    }
}
