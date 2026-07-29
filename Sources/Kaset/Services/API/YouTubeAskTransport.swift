import Foundation
import YouTubeAskCore

// MARK: - YouTubeAskHTTPResponse

struct YouTubeAskHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask HTTP response>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeAskTransportError

enum YouTubeAskTransportError: Error, Sendable {
    case responseTooLarge
    case invalidResponse
}

// MARK: - YouTubeAskTransport

final class YouTubeAskTransport: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.configuration = configuration
    }

    func send(_ request: URLRequest) async throws -> YouTubeAskHTTPResponse {
        guard let originURL = request.url else {
            throw YouTubeAskTransportError.invalidResponse
        }
        let loader = YouTubeAskBoundedResponseLoader(
            originURL: originURL,
            maximumBytes: YouTubeAskLimits.maximumResponseBytes
        )
        let (data, response) = try await loader.load(
            configuration: self.configuration,
            request: request
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeAskTransportError.invalidResponse
        }
        return YouTubeAskHTTPResponse(
            data: data,
            statusCode: httpResponse.statusCode
        )
    }
}

// MARK: - YouTubeAskBoundedResponseLoader

private final class YouTubeAskBoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let scheme: String?
    private let host: String?
    private let port: Int?
    private let maximumBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var session: URLSession?
    private var response: URLResponse?
    private var responseData = Data()
    private var isFinished = false
    private var cancellationRequested = false

    init(originURL: URL, maximumBytes: Int) {
        self.scheme = originURL.scheme?.lowercased()
        self.host = originURL.host?.lowercased()
        self.port = Self.effectivePort(for: originURL)
        self.maximumBytes = maximumBytes
    }

    func load(
        configuration: URLSessionConfiguration,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.dataTask(with: request)

                self.lock.lock()
                if self.cancellationRequested {
                    self.isFinished = true
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.session = session
                self.lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == self.scheme,
              url.host?.lowercased() == self.host,
              Self.effectivePort(for: url) == self.port
        else {
            completionHandler(nil)
            self.finish(
                .failure(YouTubeAskTransportError.invalidResponse),
                cancelSession: true
            )
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let exceedsLimit = response.expectedContentLength > 0
            && response.expectedContentLength > Int64(self.maximumBytes)
        guard !exceedsLimit else {
            completionHandler(.cancel)
            self.finish(
                .failure(YouTubeAskTransportError.responseTooLarge),
                cancelSession: true
            )
            return
        }

        self.lock.lock()
        if !self.isFinished {
            self.response = response
            if response.expectedContentLength > 0 {
                self.responseData.reserveCapacity(
                    min(Int(response.expectedContentLength), self.maximumBytes)
                )
            }
        }
        self.lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive data: Data
    ) {
        var exceedsLimit = false
        self.lock.lock()
        if !self.isFinished {
            if data.count > self.maximumBytes - self.responseData.count {
                exceedsLimit = true
            } else {
                self.responseData.append(data)
            }
        }
        self.lock.unlock()

        if exceedsLimit {
            self.finish(
                .failure(YouTubeAskTransportError.responseTooLarge),
                cancelSession: true
            )
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                self.finish(.failure(CancellationError()), cancelSession: true)
            } else {
                self.finish(.failure(error), cancelSession: true)
            }
            return
        }

        self.lock.lock()
        let response = self.response
        let data = self.responseData
        self.lock.unlock()

        guard let response else {
            self.finish(
                .failure(YouTubeAskTransportError.invalidResponse),
                cancelSession: true
            )
            return
        }
        self.finish(.success((data, response)), cancelSession: false)
    }

    private func cancel() {
        self.lock.lock()
        self.cancellationRequested = true
        let shouldFinish = self.continuation != nil && !self.isFinished
        self.lock.unlock()
        if shouldFinish {
            self.finish(.failure(CancellationError()), cancelSession: true)
        }
    }

    private func finish(
        _ result: Result<(Data, URLResponse), any Error>,
        cancelSession: Bool
    ) {
        self.lock.lock()
        guard !self.isFinished else {
            self.lock.unlock()
            return
        }
        self.isFinished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.lock.unlock()

        if cancelSession {
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation?.resume(with: result)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }
}
