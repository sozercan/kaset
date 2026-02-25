import Foundation

/// Configurable retry policy with exponential backoff.
struct RetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 1.0, maxDelay: 8.0)

    /// Calculates the delay for a given attempt using exponential backoff.
    func delay(for attempt: Int) -> TimeInterval {
        min(self.baseDelay * pow(2.0, Double(attempt)), self.maxDelay)
    }

    /// Executes an operation with retry logic.
    @MainActor
    func execute<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0 ..< self.maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Don't retry non-retryable errors (auth, parse, invalid input)
                if let ytError = error as? YTMusicError, !ytError.isRetryable {
                    throw error
                }

                // Don't retry on last attempt
                if attempt < self.maxAttempts - 1 {
                    let delayTime = self.delay(for: attempt)
                    try await Task.sleep(for: .seconds(delayTime))
                }
            }
        }

        throw lastError ?? YTMusicError.unknown(message: "Unknown error after retries")
    }
}
