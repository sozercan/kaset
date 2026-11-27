import Foundation

final class MockURLProtocol: URLProtocol {
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let sessionIDHeader = "X-Kaset-MockURLProtocol-Session-ID"
    private static let handlersLock = NSLock()
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var handlersBySessionID: [String: RequestHandler] = [:]

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

    override func stopLoading() {}

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

    static func setRequestHandler(for session: URLSession, _ handler: @escaping RequestHandler) {
        self.handlersLock.withLock {
            guard let sessionID = session.configuration.httpAdditionalHeaders?[Self.sessionIDHeader] as? String else {
                return
            }
            Self.handlersBySessionID[sessionID] = handler
        }
    }

    static func reset(session: URLSession) {
        self.handlersLock.withLock {
            guard let sessionID = session.configuration.httpAdditionalHeaders?[Self.sessionIDHeader] as? String else {
                return
            }
            Self.handlersBySessionID.removeValue(forKey: sessionID)
        }
    }

    private static func handler(for request: URLRequest) -> RequestHandler? {
        guard let sessionID = request.value(forHTTPHeaderField: sessionIDHeader) else {
            return nil
        }
        return Self.handlersLock.withLock {
            Self.handlersBySessionID[sessionID]
        }
    }
}
