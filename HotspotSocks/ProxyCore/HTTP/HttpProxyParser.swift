import Foundation
import Network

enum HttpProxyRequestKind: Equatable, Sendable {
    case connect
    case forward
}

struct HttpProxyRequest: Equatable, Sendable {
    let kind: HttpProxyRequestKind
    let destination: Socks5ConnectRequest
    let initialUpstreamData: Data
}

struct PacResourceRequest: Equatable, Sendable {
    let sendsBody: Bool
}

enum HttpInitialRequest: Equatable, Sendable {
    case proxy(HttpProxyRequest)
    case pac(PacResourceRequest)
}

enum HttpProxyParserError: LocalizedError, Equatable {
    case headerTooLarge
    case malformedRequest
    case unsupportedScheme
    case methodNotAllowed

    var errorDescription: String? {
        switch self {
        case .headerTooLarge: "HTTP request headers exceed the 64 KiB limit."
        case .malformedRequest: "Malformed HTTP proxy request."
        case .unsupportedScheme: "Only HTTP forwarding and HTTPS CONNECT are supported."
        case .methodNotAllowed: "The requested method is not allowed for this resource."
        }
    }
}

struct HttpProxyParser {
    static let maximumHeaderLength = 64 * 1_024
    private static let headerTerminator = Data([13, 10, 13, 10])
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> HttpInitialRequest? {
        buffer.append(data)
        guard let terminatorRange = buffer.range(of: Self.headerTerminator) else {
            if buffer.count > Self.maximumHeaderLength {
                throw HttpProxyParserError.headerTooLarge
            }
            return nil
        }

        let headerEnd = terminatorRange.upperBound
        guard headerEnd <= Self.maximumHeaderLength else {
            throw HttpProxyParserError.headerTooLarge
        }
        let headerData = buffer[..<terminatorRange.lowerBound]
        let trailingData = Data(buffer[headerEnd...])
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw HttpProxyParserError.malformedRequest
        }
        return try Self.parse(headerText: headerText, trailingData: trailingData)
    }

    private static func parse(headerText: String, trailingData: Data) throws -> HttpInitialRequest {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw HttpProxyParserError.malformedRequest
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.0" || requestParts[2] == "HTTP/1.1" else {
            throw HttpProxyParserError.malformedRequest
        }

        let method = String(requestParts[0])
        guard isToken(method) else { throw HttpProxyParserError.malformedRequest }
        let target = String(requestParts[1])
        let version = String(requestParts[2])
        let headers = try parseHeaders(Array(lines.dropFirst()))

        if target == "/wpad.dat" || target.hasPrefix("/wpad.dat?") {
            guard trailingData.isEmpty else { throw HttpProxyParserError.malformedRequest }
            switch method {
            case "GET": return .pac(PacResourceRequest(sendsBody: true))
            case "HEAD": return .pac(PacResourceRequest(sendsBody: false))
            default: throw HttpProxyParserError.methodNotAllowed
            }
        }

        if method == "CONNECT" {
            let destination = try parseAuthority(target, defaultPort: nil)
            return .proxy(HttpProxyRequest(
                kind: .connect,
                destination: destination,
                initialUpstreamData: trailingData
            ))
        }

        guard let components = URLComponents(string: target),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host,
              !host.isEmpty else {
            if target.lowercased().hasPrefix("https://") {
                throw HttpProxyParserError.unsupportedScheme
            }
            throw HttpProxyParserError.malformedRequest
        }
        let port = components.port ?? 80
        guard (1...65_535).contains(port) else { throw HttpProxyParserError.malformedRequest }
        let destination = Socks5ConnectRequest(address: try address(for: host), port: UInt16(port))
        var originTarget = components.percentEncodedPath
        if originTarget.isEmpty { originTarget = "/" }
        if let query = components.percentEncodedQuery { originTarget += "?\(query)" }

        var rewrittenHeaders = headers.filter {
            !["host", "connection", "proxy-connection", "proxy-authorization"].contains($0.name.lowercased())
        }
        rewrittenHeaders.append(("Host", formattedAuthority(host: host, port: port, defaultPort: 80)))
        // One origin connection per client request keeps cross-origin proxy reuse from
        // bypassing destination parsing and policy evaluation.
        rewrittenHeaders.append(("Connection", " close"))
        var rewritten = "\(method) \(originTarget) \(version)\r\n"
        for header in rewrittenHeaders {
            rewritten += "\(header.name):\(header.value)\r\n"
        }
        rewritten += "\r\n"
        guard var initialData = rewritten.data(using: .isoLatin1) else {
            throw HttpProxyParserError.malformedRequest
        }
        initialData.append(trailingData)
        return .proxy(HttpProxyRequest(kind: .forward, destination: destination, initialUpstreamData: initialData))
    }

    private static func parseHeaders(_ lines: [String]) throws -> [(name: String, value: String)] {
        try lines.map { line in
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let separator = line.firstIndex(of: ":") else {
                throw HttpProxyParserError.malformedRequest
            }
            let name = String(line[..<separator])
            guard isToken(name) else { throw HttpProxyParserError.malformedRequest }
            let value = String(line[separator...].dropFirst())
            guard !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
                throw HttpProxyParserError.malformedRequest
            }
            return (name, value)
        }
    }

    private static func parseAuthority(_ authority: String, defaultPort: Int?) throws -> Socks5ConnectRequest {
        let host: String
        let port: Int
        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]") else {
                throw HttpProxyParserError.malformedRequest
            }
            host = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            let suffix = authority[authority.index(after: closingBracket)...]
            guard suffix.first == ":", let parsedPort = Int(suffix.dropFirst()) else {
                throw HttpProxyParserError.malformedRequest
            }
            port = parsedPort
        } else if let separator = authority.lastIndex(of: ":"),
                  !authority[..<separator].contains(":") {
            host = String(authority[..<separator])
            guard let parsedPort = Int(authority[authority.index(after: separator)...]) else {
                throw HttpProxyParserError.malformedRequest
            }
            port = parsedPort
        } else if let defaultPort {
            host = authority
            port = defaultPort
        } else {
            throw HttpProxyParserError.malformedRequest
        }
        guard !host.isEmpty, (1...65_535).contains(port) else {
            throw HttpProxyParserError.malformedRequest
        }
        return Socks5ConnectRequest(address: try address(for: host), port: UInt16(port))
    }

    private static func address(for host: String) throws -> Socks5Address {
        if let ipv4 = IPv4Address(host) { return .ipv4(Array(ipv4.rawValue)) }
        if let ipv6 = IPv6Address(host) { return .ipv6(Array(ipv6.rawValue)) }
        guard !host.utf8.isEmpty, host.utf8.count <= 255,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw HttpProxyParserError.malformedRequest
        }
        return .domain(host)
    }

    private static func formattedAuthority(host: String, port: Int, defaultPort: Int) -> String {
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? formattedHost : "\(formattedHost):\(port)"
    }

    private static func isToken(_ value: String) -> Bool {
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.value > 31 && $0.value < 127 && !separators.contains($0)
        }
    }
}
