import Foundation
import Network

enum AccessPolicyBlockReason: String, Equatable, Sendable {
    case unspecified
    case loopback
    case linkLocal
    case privateNetwork
    case multicast
    case invalidAddress
}

enum AccessPolicyDecision: Equatable, Sendable {
    case allowed
    case blocked(AccessPolicyBlockReason)
}

/// Restricts both proxy ingress and requested destinations so the listener does not
/// become an unrestricted open proxy or an SSRF path into the iPhone's local network.
struct AccessPolicy: Sendable {
    let allowPrivateNetworks: Bool

    func evaluate(destination: Socks5Address) -> AccessPolicyDecision {
        switch destination {
        case let .ipv4(bytes):
            evaluateIPv4(bytes)
        case let .ipv6(bytes):
            evaluateIPv6(bytes)
        case let .domain(name):
            evaluateDomain(name)
        }
    }

    func evaluate(remoteEndpoint: NWEndpoint?) -> AccessPolicyDecision? {
        guard let remoteEndpoint, case let .hostPort(host, _) = remoteEndpoint else { return nil }
        return evaluate(destination: socksAddress(from: host))
    }

    func permitsClient(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            return isLocalClientIPv4(Array(address.rawValue))
        case let .ipv6(address):
            let bytes = Array(address.rawValue)
            if let mapped = mappedIPv4(bytes) { return isLocalClientIPv4(mapped) }
            return isLoopbackIPv6(bytes) || isLinkLocalIPv6(bytes) || isUniqueLocalIPv6(bytes)
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private func evaluateDomain(_ rawName: String) -> AccessPolicyDecision {
        var name = rawName.lowercased()
        if name.last == "." { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty,
              name.utf8.count <= 253,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains(where: { $0.isWhitespace }) else {
            return .blocked(.invalidAddress)
        }

        if let address = IPv4Address(name) {
            return evaluateIPv4(Array(address.rawValue))
        }
        if let address = IPv6Address(name) {
            return evaluateIPv6(Array(address.rawValue))
        }
        if name == "localhost" || name.hasSuffix(".localhost") {
            return .blocked(.loopback)
        }
        if name == "local" || name.hasSuffix(".local") {
            return allowPrivateNetworks ? .allowed : .blocked(.linkLocal)
        }
        return .allowed
    }

    private func evaluateIPv4(_ bytes: [UInt8]) -> AccessPolicyDecision {
        guard bytes.count == 4 else { return .blocked(.invalidAddress) }
        if bytes[0] == 0 { return .blocked(.unspecified) }
        if bytes[0] == 127 { return .blocked(.loopback) }
        if bytes[0] >= 224 { return .blocked(.multicast) }
        if bytes[0] == 169, bytes[1] == 254 {
            return allowPrivateNetworks ? .allowed : .blocked(.linkLocal)
        }
        if isPrivateIPv4(bytes) || isSharedIPv4(bytes) {
            return allowPrivateNetworks ? .allowed : .blocked(.privateNetwork)
        }
        return .allowed
    }

    private func evaluateIPv6(_ bytes: [UInt8]) -> AccessPolicyDecision {
        guard bytes.count == 16 else { return .blocked(.invalidAddress) }
        if let mapped = mappedIPv4(bytes) { return evaluateIPv4(mapped) }
        if bytes.allSatisfy({ $0 == 0 }) { return .blocked(.unspecified) }
        if isLoopbackIPv6(bytes) { return .blocked(.loopback) }
        if bytes[0] == 0xFF { return .blocked(.multicast) }
        if isLinkLocalIPv6(bytes) {
            return allowPrivateNetworks ? .allowed : .blocked(.linkLocal)
        }
        if isUniqueLocalIPv6(bytes) {
            return allowPrivateNetworks ? .allowed : .blocked(.privateNetwork)
        }
        return .allowed
    }

    private func socksAddress(from host: NWEndpoint.Host) -> Socks5Address {
        switch host {
        case let .ipv4(address): .ipv4(Array(address.rawValue))
        case let .ipv6(address): .ipv6(Array(address.rawValue))
        case let .name(name, _): .domain(name)
        @unknown default: .domain("")
        }
    }

    private func isLocalClientIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 127
            || (bytes[0] == 169 && bytes[1] == 254)
            || isPrivateIPv4(bytes)
            || isSharedIPv4(bytes)
    }

    private func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }

    private func isSharedIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    private func isLoopbackIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
    }

    private func isLinkLocalIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
    }

    private func isUniqueLocalIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && (bytes[0] & 0xFE) == 0xFC
    }

    private func mappedIPv4(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16,
              bytes.prefix(10).allSatisfy({ $0 == 0 }),
              bytes[10] == 0xFF,
              bytes[11] == 0xFF else { return nil }
        return Array(bytes[12..<16])
    }
}
