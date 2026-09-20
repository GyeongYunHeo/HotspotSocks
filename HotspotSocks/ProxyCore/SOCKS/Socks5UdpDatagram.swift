import Foundation

struct Socks5UdpDatagram: Equatable, Sendable {
    let destination: Socks5ConnectRequest
    let payload: Data
}

enum Socks5UdpDatagramError: Error, Equatable, LocalizedError, Sendable {
    case datagramTooLarge
    case truncated
    case invalidReservedField
    case fragmentationNotSupported(UInt8)
    case unsupportedAddressType(UInt8)
    case invalidDomain
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .datagramTooLarge: "The SOCKS5 UDP datagram exceeded 65,535 bytes."
        case .truncated: "The SOCKS5 UDP datagram header was truncated."
        case .invalidReservedField: "The SOCKS5 UDP reserved field was not zero."
        case let .fragmentationNotSupported(fragment): "SOCKS5 UDP fragmentation is not supported (FRAG=\(fragment))."
        case let .unsupportedAddressType(type): "Unsupported SOCKS5 UDP address type: \(type)."
        case .invalidDomain: "The SOCKS5 UDP destination domain is invalid."
        case .invalidPort: "The SOCKS5 UDP destination port is invalid."
        }
    }
}

enum Socks5UdpCodec {
    static let maximumDatagramSize = 65_535

    static func parse(_ datagram: Data) throws -> Socks5UdpDatagram {
        guard datagram.count <= maximumDatagramSize else {
            throw Socks5UdpDatagramError.datagramTooLarge
        }
        guard datagram.count >= 4 else { throw Socks5UdpDatagramError.truncated }
        guard byte(in: datagram, at: 0) == 0, byte(in: datagram, at: 1) == 0 else {
            throw Socks5UdpDatagramError.invalidReservedField
        }

        let fragment = byte(in: datagram, at: 2)!
        guard fragment == 0 else {
            throw Socks5UdpDatagramError.fragmentationNotSupported(fragment)
        }
        let typeByte = byte(in: datagram, at: 3)!
        guard let type = Socks5AddressType(rawValue: typeByte) else {
            throw Socks5UdpDatagramError.unsupportedAddressType(typeByte)
        }

        let parsed: (address: Socks5Address, portOffset: Int)
        switch type {
        case .ipv4:
            guard datagram.count >= 10 else { throw Socks5UdpDatagramError.truncated }
            parsed = (.ipv4(Array(data(in: datagram, offsets: 4..<8))), 8)
        case .domain:
            guard let lengthByte = byte(in: datagram, at: 4) else {
                throw Socks5UdpDatagramError.truncated
            }
            let length = Int(lengthByte)
            guard length > 0 else { throw Socks5UdpDatagramError.invalidDomain }
            let portOffset = 5 + length
            guard datagram.count >= portOffset + 2 else { throw Socks5UdpDatagramError.truncated }
            guard let domain = String(
                data: data(in: datagram, offsets: 5..<portOffset),
                encoding: .utf8
            ), !domain.isEmpty else {
                throw Socks5UdpDatagramError.invalidDomain
            }
            parsed = (.domain(domain), portOffset)
        case .ipv6:
            guard datagram.count >= 22 else { throw Socks5UdpDatagramError.truncated }
            parsed = (.ipv6(Array(data(in: datagram, offsets: 4..<20))), 20)
        }

        let port = (UInt16(byte(in: datagram, at: parsed.portOffset)!) << 8)
            | UInt16(byte(in: datagram, at: parsed.portOffset + 1)!)
        guard port > 0 else { throw Socks5UdpDatagramError.invalidPort }
        let payloadOffset = parsed.portOffset + 2
        return Socks5UdpDatagram(
            destination: Socks5ConnectRequest(address: parsed.address, port: port),
            payload: Data(data(in: datagram, offsets: payloadOffset..<datagram.count))
        )
    }

    static func encapsulate(
        payload: Data,
        sourceAddress: Socks5Address,
        sourcePort: UInt16
    ) throws -> Data {
        guard sourcePort > 0 else { throw Socks5UdpDatagramError.invalidPort }
        var result = Data([0, 0, 0])
        do {
            result.append(try sourceAddress.socks5WireData)
        } catch Socks5Error.invalidDomain {
            throw Socks5UdpDatagramError.invalidDomain
        } catch {
            throw Socks5UdpDatagramError.truncated
        }
        result.append(UInt8(sourcePort >> 8))
        result.append(UInt8(sourcePort & 0xFF))
        result.append(payload)
        guard result.count <= maximumDatagramSize else {
            throw Socks5UdpDatagramError.datagramTooLarge
        }
        return result
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    private static func data(in data: Data, offsets: Range<Int>) -> Data.SubSequence {
        let lowerBound = data.startIndex + offsets.lowerBound
        let upperBound = data.startIndex + offsets.upperBound
        return data[lowerBound..<upperBound]
    }
}
