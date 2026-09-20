import Foundation

enum Socks5Address: Equatable, Hashable, Sendable {
    case ipv4([UInt8])
    case domain(String)
    case ipv6([UInt8])

    var displayValue: String {
        switch self {
        case let .ipv4(bytes):
            return bytes.map(String.init).joined(separator: ".")
        case let .domain(name):
            return name
        case let .ipv6(bytes):
            guard bytes.count == 16 else { return "<invalid IPv6>" }
            return stride(from: 0, to: bytes.count, by: 2).map { index in
                String(format: "%02x%02x", bytes[index], bytes[index + 1])
            }.joined(separator: ":")
        }
    }
}

struct Socks5ConnectRequest: Equatable, Hashable, Sendable {
    let address: Socks5Address
    let port: UInt16
}

enum Socks5Message: Equatable, Sendable {
    case greeting(methods: [UInt8])
    case connectRequest(Socks5ConnectRequest)
    case udpAssociateRequest(Socks5ConnectRequest)
}

extension Socks5Reply {
    var responseData: Data {
        Data([
            Socks5Protocol.version, rawValue, Socks5Protocol.reserved,
            Socks5AddressType.ipv4.rawValue, 0, 0, 0, 0, 0, 0
        ])
    }

    func responseData(boundAddress: Socks5Address, boundPort: UInt16) throws -> Data {
        var response = Data([Socks5Protocol.version, rawValue, Socks5Protocol.reserved])
        response.append(try boundAddress.socks5WireData)
        response.append(UInt8(boundPort >> 8))
        response.append(UInt8(boundPort & 0xFF))
        return response
    }
}

extension Socks5Address {
    var socks5WireData: Data {
        get throws {
            switch self {
            case let .ipv4(bytes):
                guard bytes.count == 4 else { throw Socks5Error.malformedRequest }
                return Data([Socks5AddressType.ipv4.rawValue] + bytes)
            case let .domain(domain):
                let bytes = Array(domain.utf8)
                guard !bytes.isEmpty, bytes.count <= 255 else { throw Socks5Error.invalidDomain }
                return Data([Socks5AddressType.domain.rawValue, UInt8(bytes.count)] + bytes)
            case let .ipv6(bytes):
                guard bytes.count == 16 else { throw Socks5Error.malformedRequest }
                return Data([Socks5AddressType.ipv6.rawValue] + bytes)
            }
        }
    }
}
