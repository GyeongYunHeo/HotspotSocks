import Foundation

enum Socks5Error: Error, Equatable, LocalizedError, Sendable {
    case malformedGreeting
    case unsupportedVersion(UInt8)
    case malformedRequest
    case unsupportedCommand(UInt8)
    case unsupportedAddressType(UInt8)
    case invalidDomain
    case invalidPort
    case handshakeTooLarge
    case handshakeTimeout
    case unexpectedMessage
    case connectionClosed
    case idleTimeout

    var errorDescription: String? {
        switch self {
        case .malformedGreeting: "Malformed SOCKS5 greeting."
        case let .unsupportedVersion(version): "Unsupported SOCKS version: \(version)."
        case .malformedRequest: "Malformed SOCKS5 request."
        case let .unsupportedCommand(command): "Unsupported SOCKS5 command: \(command)."
        case let .unsupportedAddressType(type): "Unsupported SOCKS5 address type: \(type)."
        case .invalidDomain: "The SOCKS5 destination domain is invalid."
        case .invalidPort: "The SOCKS5 destination port is invalid."
        case .handshakeTooLarge: "The SOCKS5 handshake exceeded its size limit."
        case .handshakeTimeout: "The SOCKS5 handshake exceeded its time limit."
        case .unexpectedMessage: "A SOCKS5 message arrived in an unexpected state."
        case .connectionClosed: "The connection closed during the SOCKS5 handshake."
        case .idleTimeout: "The SOCKS5 session exceeded its idle timeout."
        }
    }
}
