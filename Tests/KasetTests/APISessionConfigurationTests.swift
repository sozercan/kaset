// APISessionConfigurationTests.swift
// KasetTests
//
// Tests for the shared API URLSession configuration using Swift Testing framework.

import Foundation
import Testing
@testable import Kaset

// MARK: - APISessionConfigurationTests

struct APISessionConfigurationTests {
    /// Regression guard for the "Data Error" outage: the API session must NOT set an
    /// `Accept-Encoding` header. Setting it manually disables URLSession's transparent
    /// decompression, so responses YouTube serves compressed (Brotli behind the EU consent
    /// redirect, gzip, etc.) arrive as raw bytes. The INNERTUBE key regex / JSON parsing then
    /// fail and every request throws a parse error.
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
