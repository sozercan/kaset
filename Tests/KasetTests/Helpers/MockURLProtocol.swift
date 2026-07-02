import Foundation

/// A custom URLProtocol that intercepts network requests for testing.
/// Allows tests to provide mock responses without making real network calls.
final class MockURLProtocol: URLProtocol {
    /// Handler type for processing requests.
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let sessionIDHeader = "X-Kaset-MockURLProtocol-Session-ID"
    private static let handlersLock = NSLock()
    nonisolated(unsafe) static var handlersBySessionID: [String: RequestHandler] = [:]

    /// Legacy fallback handler for older tests. Prefer `makeMockSession(handler:)`
    /// so parallel suites cannot clear or replace each other's handler.
    nonisolated(unsafe) static var requestHandler: RequestHandler?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(for: request) else {
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
    static func makeMockSession(handler: RequestHandler? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let sessionID = UUID().uuidString
        configuration.httpAdditionalHeaders = [Self.sessionIDHeader: sessionID]
        if let handler {
            Self.handlersLock.withLock {
                Self.handlersBySessionID[sessionID] = handler
            }
        }

        return URLSession(configuration: configuration)
    }

    /// Sets the request handler associated with a specific mock session.
    static func setRequestHandler(for session: URLSession, _ handler: @escaping RequestHandler) {
        guard let sessionID = session.configuration.httpAdditionalHeaders?[sessionIDHeader] as? String else {
            self.requestHandler = handler
            return
        }
        Self.handlersLock.withLock {
            Self.handlersBySessionID[sessionID] = handler
        }
    }

    /// Removes the request handler associated with a specific mock session.
    static func reset(session: URLSession) {
        guard let sessionID = session.configuration.httpAdditionalHeaders?[sessionIDHeader] as? String else {
            return
        }
        _ = Self.handlersLock.withLock {
            Self.handlersBySessionID.removeValue(forKey: sessionID)
        }
    }

    /// Resets all request handlers.
    static func reset() {
        self.handlersLock.withLock {
            Self.handlersBySessionID.removeAll()
            Self.requestHandler = nil
        }
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

    private static func handler(for request: URLRequest) -> RequestHandler? {
        let sessionID = request.value(forHTTPHeaderField: Self.sessionIDHeader)
        let sessionHandler = sessionID.flatMap { id in
            Self.handlersLock.withLock {
                Self.handlersBySessionID[id]
            }
        }
        return sessionHandler ?? Self.requestHandler
    }
}
