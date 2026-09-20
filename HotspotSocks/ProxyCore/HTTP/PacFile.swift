import Foundation

enum PacFileGenerator {
    static func script(proxyHost: String, proxyPort: UInt16) -> Data? {
        guard proxyPort > 0,
              !proxyHost.isEmpty,
              proxyHost.unicodeScalars.allSatisfy({ allowedHostCharacters.contains($0) }) else {
            return nil
        }
        let formattedHost = proxyHost.contains(":") ? "[\(proxyHost)]" : proxyHost
        let script = """
        function FindProxyForURL(url, host) {
            return "PROXY \(formattedHost):\(proxyPort)";
        }

        """
        return Data(script.utf8)
    }

    static func response(proxyHost: String, proxyPort: UInt16, sendsBody: Bool) -> Data? {
        guard let body = script(proxyHost: proxyHost, proxyPort: proxyPort) else { return nil }
        var response = Data("""
        HTTP/1.1 200 OK\r
        Content-Type: application/x-ns-proxy-autoconfig\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store, no-cache, must-revalidate\r
        Connection: close\r
        \r

        """.utf8)
        if sendsBody { response.append(body) }
        return response
    }

    private static let allowedHostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:%"
    )
}
