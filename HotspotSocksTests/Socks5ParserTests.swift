import Foundation
import XCTest
@testable import HotspotSocks

final class Socks5ParserTests: XCTestCase {
    func testGreetingInSinglePacket() throws {
        var parser = Socks5Parser()
        XCTAssertEqual(try parser.append(Data([0x05, 0x01, 0x00])), [.greeting(methods: [0x00])])
        XCTAssertEqual(parser.state, .request)
    }

    func testGreetingByteByByteFragmentation() throws {
        var parser = Socks5Parser()
        XCTAssertEqual(try parser.append(Data([0x05])), [])
        XCTAssertEqual(try parser.append(Data([0x01])), [])
        XCTAssertEqual(try parser.append(Data([0x00])), [.greeting(methods: [0x00])])
    }

    func testGreetingAndRequestInOneReceive() throws {
        var parser = Socks5Parser()
        let coalesced: [UInt8] = [
            0x05, 0x01, 0x00,
            0x05, 0x01, 0x00, 0x01, 1, 1, 1, 1, 0x01, 0xBB
        ]
        XCTAssertEqual(
            try parser.append(Data(coalesced)),
            [.greeting(methods: [0x00]), .connectRequest(.init(address: .ipv4([1, 1, 1, 1]), port: 443))]
        )
    }

    func testIPv4Request() throws {
        var parser = try requestParser()
        XCTAssertEqual(
            try parser.append(Data(ipv4Request)),
            [.connectRequest(.init(address: .ipv4([1, 2, 3, 4]), port: 443))]
        )
    }

    func testDomainRequest() throws {
        var parser = try requestParser()
        let request: [UInt8] = [
            0x05, 0x01, 0x00, 0x03, 0x0B,
            0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x2E, 0x63, 0x6F, 0x6D,
            0x01, 0xBB
        ]
        XCTAssertEqual(
            try parser.append(Data(request)),
            [.connectRequest(.init(address: .domain("example.com"), port: 443))]
        )
    }

    func testIPv6Request() throws {
        var parser = try requestParser()
        let address: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let request = [0x05, 0x01, 0x00, 0x04] + address + [0x01, 0xBB]
        XCTAssertEqual(
            try parser.append(Data(request)),
            [.connectRequest(.init(address: .ipv6(address), port: 443))]
        )
    }

    func testMalformedVersion() {
        var parser = Socks5Parser()
        XCTAssertThrowsError(try parser.append(Data([0x04]))) { error in
            XCTAssertEqual(error as? Socks5Error, .unsupportedVersion(0x04))
        }
    }

    func testUnsupportedCommand() throws {
        var parser = try requestParser()
        XCTAssertThrowsError(try parser.append(Data([0x05, 0x02, 0x00, 0x01]))) { error in
            XCTAssertEqual(error as? Socks5Error, .unsupportedCommand(0x02))
        }
    }

    func testUnsupportedAddressType() throws {
        var parser = try requestParser()
        XCTAssertThrowsError(try parser.append(Data([0x05, 0x01, 0x00, 0x02]))) { error in
            XCTAssertEqual(error as? Socks5Error, .unsupportedAddressType(0x02))
        }
    }

    func testGreetingIsPreservedWhenCoalescedRequestFails() {
        var parser = Socks5Parser()
        let data = Data([0x05, 0x01, 0x00, 0x05, 0x02, 0x00, 0x01])
        XCTAssertThrowsError(try parser.append(data)) { error in
            XCTAssertEqual(error as? Socks5Error, .unsupportedCommand(0x02))
        }
        XCTAssertEqual(parser.takeMessagesBeforeFailure(), [.greeting(methods: [0x00])])
    }

    func testTruncatedDomainNeedsMoreData() throws {
        var parser = try requestParser()
        XCTAssertEqual(try parser.append(Data([0x05, 0x01, 0x00, 0x03, 0x05, 0x61, 0x62])), [])
        XCTAssertEqual(parser.state, .request)
    }

    func testZeroLengthDomainIsRejected() throws {
        var parser = try requestParser()
        XCTAssertThrowsError(try parser.append(Data([0x05, 0x01, 0x00, 0x03, 0x00]))) { error in
            XCTAssertEqual(error as? Socks5Error, .invalidDomain)
        }
    }

    func testZeroPortIsRejected() throws {
        var parser = try requestParser()
        let request = Data([0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0, 0])
        XCTAssertThrowsError(try parser.append(request)) { error in
            XCTAssertEqual(error as? Socks5Error, .invalidPort)
        }
    }

    func testPortUsesNetworkByteOrder() throws {
        var parser = try requestParser()
        let request: [UInt8] = [0x05, 0x01, 0x00, 0x01, 8, 8, 8, 8, 0x12, 0x34]
        XCTAssertEqual(
            try parser.append(Data(request)),
            [.connectRequest(.init(address: .ipv4([8, 8, 8, 8]), port: 0x1234))]
        )
    }

    func testCoalescedPayloadRemainsAfterMessages() throws {
        var parser = Socks5Parser()
        let payload = Data("GET / HTTP/1.1\r\n".utf8)
        let bytes = Data([0x05, 0x01, 0x00] + ipv4Request) + payload
        XCTAssertEqual(try parser.append(bytes).count, 2)
        XCTAssertEqual(parser.takeRemainingData(), payload)
    }

    private var ipv4Request: [UInt8] {
        [0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0x01, 0xBB]
    }

    private func requestParser() throws -> Socks5Parser {
        var parser = Socks5Parser()
        _ = try parser.append(Data([0x05, 0x01, 0x00]))
        return parser
    }
}
