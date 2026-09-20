import Foundation
import Network

enum Socks5Protocol {
    static let version: UInt8 = 0x05
    static let reserved: UInt8 = 0x00
    static let noAuthentication: UInt8 = 0x00
    static let noAcceptableMethods: UInt8 = 0xFF
}

enum Socks5Command: UInt8, Sendable {
    case connect = 0x01
    case bind = 0x02
    case udpAssociate = 0x03
}

enum Socks5AddressType: UInt8, Sendable {
    case ipv4 = 0x01
    case domain = 0x03
    case ipv6 = 0x04
}

enum Socks5Reply: UInt8, Sendable {
    case succeeded = 0x00
    case generalFailure = 0x01
    case connectionNotAllowed = 0x02
    case networkUnreachable = 0x03
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case ttlExpired = 0x06
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08
}

extension Socks5Reply {
    static func forUpstreamError(_ error: NWError) -> Socks5Reply {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED: .connectionRefused
            case .ENETDOWN, .ENETUNREACH: .networkUnreachable
            case .EHOSTDOWN, .EHOSTUNREACH: .hostUnreachable
            default: .generalFailure
            }
        case .dns:
            .hostUnreachable
        case .tls:
            .generalFailure
        case .wifiAware:
            .generalFailure
        @unknown default:
            .generalFailure
        }
    }
}
