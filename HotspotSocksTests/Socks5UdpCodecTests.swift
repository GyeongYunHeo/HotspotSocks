import Foundation
import XCTest
@testable import HotspotSocks

final class Socks5UdpCodecTests: XCTestCase {
    func testUdpAssociateCommandAllowsUnspecifiedClientEndpoint() throws {
        var parser = Socks5Parser()
        let bytes = Data([
            0x05, 0x01, 0x00,
            0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertEqual(
            try parser.append(bytes),
            [
                .greeting(methods: [0]),
                .udpAssociateRequest(.init(address: .ipv4([0, 0, 0, 0]), port: 0)),
            ]
        )
    }

    func testIPv4DatagramAndNetworkByteOrderPort() throws {
        let payload = Data("udp".utf8)
        let packet = Data([0, 0, 0, 0x01, 192, 0, 2, 10, 0x12, 0x34]) + payload
        XCTAssertEqual(
            try Socks5UdpCodec.parse(packet),
            .init(destination: .init(address: .ipv4([192, 0, 2, 10]), port: 0x1234), payload: payload)
        )
    }

    func testDomainDatagram() throws {
        let domain = Array("example.com".utf8)
        let packet = Data([0, 0, 0, 0x03, UInt8(domain.count)] + domain + [0, 53, 1, 2])
        XCTAssertEqual(
            try Socks5UdpCodec.parse(packet),
            .init(destination: .init(address: .domain("example.com"), port: 53), payload: Data([1, 2]))
        )
    }

    func testIPv6Datagram() throws {
        let address: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let packet = Data([0, 0, 0, 0x04] + address + [0x01, 0xBB])
        XCTAssertEqual(
            try Socks5UdpCodec.parse(packet),
            .init(destination: .init(address: .ipv6(address), port: 443), payload: Data())
        )
    }

    func testResponseEncapsulation() throws {
        XCTAssertEqual(
            try Socks5UdpCodec.encapsulate(
                payload: Data([0xCA, 0xFE]),
                sourceAddress: .ipv4([8, 8, 8, 8]),
                sourcePort: 53
            ),
            Data([0, 0, 0, 0x01, 8, 8, 8, 8, 0, 53, 0xCA, 0xFE])
        )
    }

    func testInvalidReservedAndFragmentAreRejected() {
        XCTAssertThrowsError(try Socks5UdpCodec.parse(Data([1, 0, 0, 1, 1, 1, 1, 1, 0, 53]))) {
            XCTAssertEqual($0 as? Socks5UdpDatagramError, .invalidReservedField)
        }
        XCTAssertThrowsError(try Socks5UdpCodec.parse(Data([0, 0, 1, 1, 1, 1, 1, 1, 0, 53]))) {
            XCTAssertEqual($0 as? Socks5UdpDatagramError, .fragmentationNotSupported(1))
        }
    }

    func testTruncatedAddressHeadersAreRejected() {
        let packets = [
            Data([0, 0, 0, 0x01, 1, 2]),
            Data([0, 0, 0, 0x03, 4, 0x61]),
            Data([0, 0, 0, 0x04, 0, 1]),
        ]
        for packet in packets {
            XCTAssertThrowsError(try Socks5UdpCodec.parse(packet)) {
                XCTAssertEqual($0 as? Socks5UdpDatagramError, .truncated)
            }
        }
    }

    func testZeroLengthPayloadAndMaximumDatagramAreAccepted() throws {
        let header = Data([0, 0, 0, 0x01, 203, 0, 113, 1, 0, 53])
        XCTAssertEqual(try Socks5UdpCodec.parse(header).payload, Data())

        let maximumPacket = header + Data(repeating: 0xA5, count: Socks5UdpCodec.maximumDatagramSize - header.count)
        XCTAssertEqual(try Socks5UdpCodec.parse(maximumPacket).payload.count, 65_525)
    }

    func testOversizedDatagramAndZeroDestinationPortAreRejected() {
        XCTAssertThrowsError(
            try Socks5UdpCodec.parse(Data(repeating: 0, count: Socks5UdpCodec.maximumDatagramSize + 1))
        ) {
            XCTAssertEqual($0 as? Socks5UdpDatagramError, .datagramTooLarge)
        }
        XCTAssertThrowsError(
            try Socks5UdpCodec.parse(Data([0, 0, 0, 1, 8, 8, 8, 8, 0, 0]))
        ) {
            XCTAssertEqual($0 as? Socks5UdpDatagramError, .invalidPort)
        }
    }

    func testNonZeroDataStartIndexRegression() throws {
        var packet = Data([0xAA, 0xBB])
        packet.append(Data([0, 0, 0, 0x01, 1, 1, 1, 1, 0, 53, 7]))
        packet.removeFirst(2)
        XCTAssertEqual(try Socks5UdpCodec.parse(packet).payload, Data([7]))
    }
}
