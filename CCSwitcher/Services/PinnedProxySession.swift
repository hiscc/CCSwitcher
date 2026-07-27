import Foundation
import CFNetwork

enum PinnedProxySession {
    static let host = "127.0.0.1"
    static let port = 7890

    static let shared = URLSession(configuration: makeConfiguration())

    static func makeConfiguration(
        host: String = PinnedProxySession.host,
        port: Int = PinnedProxySession.port
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        return configuration
    }
}
