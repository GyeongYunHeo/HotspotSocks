import Foundation
import Network

protocol UdpUpstreamConnecting: Sendable {
    func makeConnection(to destination: Socks5ConnectRequest, egressMode: EgressMode) throws -> NWConnection
}

struct UdpUpstreamConnector: UdpUpstreamConnecting {
    func makeConnection(to destination: Socks5ConnectRequest, egressMode: EgressMode) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: destination.port) else {
            throw Socks5UdpDatagramError.invalidPort
        }

        let host: NWEndpoint.Host
        switch destination.address {
        case let .ipv4(bytes):
            guard let address = IPv4Address(Data(bytes)) else {
                throw Socks5UdpDatagramError.truncated
            }
            host = .ipv4(address)
        case let .domain(domain):
            host = NWEndpoint.Host(domain)
        case let .ipv6(bytes):
            guard let address = IPv6Address(Data(bytes)) else {
                throw Socks5UdpDatagramError.truncated
            }
            host = .ipv6(address)
        }

        return NWConnection(host: host, port: port, using: makeParameters(for: egressMode))
    }

    func makeParameters(for egressMode: EgressMode) -> NWParameters {
        let parameters = NWParameters.udp
        if let interfaceType = egressMode.requiredInterfaceType {
            parameters.requiredInterfaceType = interfaceType
        }
        return parameters
    }
}
