import Foundation
import Testing
@testable import Kaset

struct APISessionConfigurationTests {
    @Test func doesNotSetManualAcceptEncoding() {
        let headers = APISessionConfiguration.make().httpAdditionalHeaders ?? [:]

        #expect(headers["Accept-Encoding"] == nil)
    }

    @Test func keepsBrowserUserAgent() {
        let headers = APISessionConfiguration.make().httpAdditionalHeaders ?? [:]

        #expect(headers["User-Agent"] as? String == APISessionConfiguration.userAgent)
    }

    @Test func retainsTunedConnectionSettings() {
        let configuration = APISessionConfiguration.make()

        #expect(configuration.httpMaximumConnectionsPerHost == 6)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
    }
}
