import Foundation
import Testing
@testable import Kaset

/// Tests for RetryPolicy.
@Suite("RetryPolicy", .serialized)
struct RetryPolicyTests {
    @Test("Default policy has expected values")
    func defaultPolicyValues() {
        let policy = RetryPolicy.default
        #expect(policy.maxAttempts == 3)
        #expect(policy.baseDelay == 1.0)
        #expect(policy.maxDelay == 8.0)
    }

    @Test(
        "Delay uses exponential backoff",
        arguments: [
            (0, 1.0),  // 1 * 2^0 = 1
            (1, 2.0),  // 1 * 2^1 = 2
            (2, 4.0),  // 1 * 2^2 = 4
            (3, 8.0),  // 1 * 2^3 = 8
            (4, 16.0), // 1 * 2^4 = 16
        ]
    )
    func delayExponentialBackoff(attempt: Int, expectedDelay: Double) {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0, maxDelay: 16.0)
        #expect(policy.delay(for: attempt) == expectedDelay)
    }

    @Test(
        "Delay is capped at maxDelay",
        arguments: [
            (5, 8.0),  // Would be 32, but capped at 8
            (10, 8.0), // Would be 1024, but capped at 8
        ]
    )
    func delayMaxCap(attempt: Int, expectedDelay: Double) {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1.0, maxDelay: 8.0)
        #expect(policy.delay(for: attempt) == expectedDelay)
    }

    @Test(
        "Delay respects custom baseDelay",
        arguments: [
            (0, 0.5), // 0.5 * 2^0 = 0.5
            (1, 1.0), // 0.5 * 2^1 = 1.0
            (2, 2.0), // 0.5 * 2^2 = 2.0
        ]
    )
    func delayWithCustomBaseDelay(attempt: Int, expectedDelay: Double) {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 10.0)
        #expect(policy.delay(for: attempt) == expectedDelay)
    }

    @Test("Custom policy stores values correctly")
    func customPolicyInit() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 2.0, maxDelay: 30.0)
        #expect(policy.maxAttempts == 5)
        #expect(policy.baseDelay == 2.0)
        #expect(policy.maxDelay == 30.0)
    }

    @Test("Execute succeeds on first attempt")
    @MainActor
    func executeSuccess() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1)

        var callCount = 0
        let result = try await policy.execute {
            callCount += 1
            return "success"
        }

        #expect(result == "success")
        #expect(callCount == 1)
    }

    @Test("Execute retries and eventually succeeds")
    @MainActor
    func executeSuccessAfterRetries() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1)

        var callCount = 0
        let result = try await policy.execute {
            callCount += 1
            if callCount < 3 {
                throw YTMusicError.networkError(underlying: URLError(.timedOut))
            }
            return "success"
        }

        #expect(result == "success")
        #expect(callCount == 3)
    }

    @Test("Execute fails after max attempts")
    @MainActor
    func executeFailsAfterMaxAttempts() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1)

        var callCount = 0
        do {
            _ = try await policy.execute { () -> String in
                callCount += 1
                throw YTMusicError.networkError(underlying: URLError(.timedOut))
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(callCount == 3)
            if case YTMusicError.networkError = error {
                // Expected
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }
    }

    @Test("Execute does not retry authExpired")
    @MainActor
    func executeDoesNotRetryAuthExpired() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1)

        var callCount = 0
        do {
            _ = try await policy.execute { () -> String in
                callCount += 1
                throw YTMusicError.authExpired
            }
            Issue.record("Should have thrown")
        } catch YTMusicError.authExpired {
            #expect(callCount == 1) // Should not retry
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Execute does not retry notAuthenticated")
    @MainActor
    func executeDoesNotRetryNotAuthenticated() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1)

        var callCount = 0
        do {
            _ = try await policy.execute { () -> String in
                callCount += 1
                throw YTMusicError.notAuthenticated
            }
            Issue.record("Should have thrown")
        } catch YTMusicError.notAuthenticated {
            #expect(callCount == 1) // Should not retry
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}
