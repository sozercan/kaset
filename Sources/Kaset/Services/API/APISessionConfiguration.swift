import Foundation

/// Builds the shared `URLSessionConfiguration` used by the YouTube Music and YouTube API clients.
///
/// Both clients present a browser-like User-Agent and tuned connection/cache settings. The
/// configuration deliberately does **not** set an `Accept-Encoding` header: URLSession negotiates
/// compression and transparently decompresses the response only when it owns the header. Setting
/// `Accept-Encoding` manually disables that automatic decompression, so responses that YouTube
/// serves compressed (e.g. Brotli behind the EU consent redirect) arrive as raw bytes that fail
/// JSON/HTML parsing. See `APISessionConfigurationTests`.
enum APISessionConfiguration {
    /// User-Agent shared by the API clients so requests look like the YouTube Music web client.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Creates the browser-like configuration used for API requests.
    static func make() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        // Only set headers that do not interfere with URLSession's automatic response handling.
        // Do NOT set Accept-Encoding here — that disables transparent decompression.
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
        ]
        // Increase connection pool for parallel requests (HTTP/2 multiplexing is automatic).
        configuration.httpMaximumConnectionsPerHost = 6
        // Use shared URL cache for transport-level caching.
        configuration.urlCache = URLCache.shared
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // Reduce timeouts for faster failure detection.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }
}
