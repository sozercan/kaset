import Foundation

/// A custom URLProtocol that intercepts network requests for testing.
/// Allows tests to provide mock responses without making real network calls.
final class MockURLProtocol: URLProtocol {
    /// Handler type for processing requests.
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// The handler to use for intercepted requests.
    /// Using nonisolated(unsafe) because URLProtocol requires static mutable state.
    nonisolated(unsafe) static var requestHandler: RequestHandler?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            let error = NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No request handler set"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }

    /// Creates a URLSession configured to use this mock protocol.
    static func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Resets the request handler.
    static func reset() {
        self.requestHandler = nil
    }

    /// Sets up a successful JSON response.
    /// - Parameters:
    ///   - json: The JSON dictionary to return.
    ///   - statusCode: The HTTP status code (default 200).
    static func setMockJSONResponse(_ json: [String: Any], statusCode: Int = 200) {
        // Pre-serialize the JSON to Data to avoid capturing non-Sendable type
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: json)
        self.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
    }

    /// Sets up an error response.
    /// - Parameter error: The error to throw.
    static func setMockError(_ error: any Error & Sendable) {
        self.requestHandler = { _ in
            throw error
        }
    }
}
