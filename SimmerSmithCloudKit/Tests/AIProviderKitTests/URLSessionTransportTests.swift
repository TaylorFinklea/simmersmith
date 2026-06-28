import Foundation
import Testing
@testable import AIProviderKit

// The default transport must NOT inherit URLSession.shared's 60s request timeout — a
// full week generation spends longer than that composing the (non-streamed) reply, so a
// 60s idle timer fires mid-generation and the call fails with "The request timed out."

@Test("default transport raises the request/resource timeouts above the 60s system default")
func defaultTimeouts() {
    let config = URLSessionTransport().session.configuration
    #expect(config.timeoutIntervalForRequest == 180)
    #expect(config.timeoutIntervalForResource == 300)
    #expect(config.timeoutIntervalForRequest > 60)
}

@Test("transport timeouts are configurable")
func customTimeouts() {
    let config = URLSessionTransport(requestTimeout: 90, resourceTimeout: 120).session.configuration
    #expect(config.timeoutIntervalForRequest == 90)
    #expect(config.timeoutIntervalForResource == 120)
}
