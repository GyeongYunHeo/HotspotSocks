import Foundation
import Network

protocol UpstreamConnecting: Sendable {
    func makeConnection(to request: Socks5ConnectRequest, egressMode: EgressMode) throws -> NWConnection
}

struct UpstreamConnector: UpstreamConnecting {
    func makeConnection(to request: Socks5ConnectRequest, egressMode: EgressMode) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: request.port) else { throw Socks5Error.invalidPort }

        let host: NWEndpoint.Host
        switch request.address {
        case let .ipv4(bytes):
            guard let address = IPv4Address(Data(bytes)) else { throw Socks5Error.malformedRequest }
            host = .ipv4(address)
        case let .domain(domain):
            host = NWEndpoint.Host(domain)
        case let .ipv6(bytes):
            guard let address = IPv6Address(Data(bytes)) else { throw Socks5Error.malformedRequest }
            host = .ipv6(address)
        }
        return NWConnection(host: host, port: port, using: makeParameters(for: egressMode))
    }

    func makeParameters(for egressMode: EgressMode) -> NWParameters {
        let parameters = NWParameters.tcp
        if let interfaceType = egressMode.requiredInterfaceType {
            parameters.requiredInterfaceType = interfaceType
        }
        return parameters
    }
}
