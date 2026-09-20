import Darwin
import Foundation

struct InterfaceAddress: Equatable, Identifiable, Sendable {
    enum Family: String, Sendable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
    }

    let interfaceName: String
    let address: String
    let family: Family

    var id: String { "\(interfaceName)-\(address)" }
}

enum InterfaceAddressResolver {
    static func activeAddresses() -> [InterfaceAddress] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var results: [InterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let socketAddress = entry.ifa_addr else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let family: InterfaceAddress.Family
            let addressLength: socklen_t
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                family = .ipv4
                addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            case AF_INET6:
                family = .ipv6
                addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            default:
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                addressLength,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let addressBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }

            results.append(
                InterfaceAddress(
                    interfaceName: String(cString: entry.ifa_name),
                    address: String(decoding: addressBytes, as: UTF8.self),
                    family: family
                )
            )
        }

        return results.sorted {
            if $0.interfaceName == $1.interfaceName { return $0.address < $1.address }
            return $0.interfaceName < $1.interfaceName
        }
    }
}
