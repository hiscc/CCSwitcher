import XCTest
import Foundation
import CFNetwork

final class PinnedProxySessionTests: XCTestCase {
    func testConfigurationPinsHTTPToLocalMixedPort() {
        let proxies = PinnedProxySession.makeConfiguration().connectionProxyDictionary

        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPEnable as String] as? Bool, true)
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPPort as String] as? Int, 7890)
    }

    func testConfigurationPinsHTTPSToLocalMixedPort() {
        let proxies = PinnedProxySession.makeConfiguration().connectionProxyDictionary

        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPSEnable as String] as? Bool, true)
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPSPort as String] as? Int, 7890)
    }

    func testUnavailableProxyDoesNotFallBackToDirect() async {
        let configuration = PinnedProxySession.makeConfiguration(port: 1)
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.data(from: URL(string: "https://example.com/")!)
            XCTFail("Request unexpectedly succeeded without the required local proxy")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
