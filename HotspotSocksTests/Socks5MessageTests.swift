import Foundation
import Network
import XCTest
@testable import HotspotSocks

final class Socks5MessageTests: XCTestCase {
    func testSuccessReplyEncoding() {
        XCTAssertEqual(
            Socks5Reply.succeeded.responseData,
            Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        )
    }

    func testCommandNotSupportedReplyEncoding() {
        XCTAssertEqual(Socks5Reply.commandNotSupported.responseData[1], 0x07)
    }

    func testUdpAssociateReplyContainsBoundEndpoint() throws {
        XCTAssertEqual(
            try Socks5Reply.succeeded.responseData(
                boundAddress: .ipv4([172, 20, 10, 1]),
                boundPort: 9877
            ),
            Data([0x05, 0, 0, 0x01, 172, 20, 10, 1, 0x26, 0x95])
        )
    }

    func testAddressDisplayValues() {
        XCTAssertEqual(Socks5Address.ipv4([192, 0, 2, 1]).displayValue, "192.0.2.1")
        XCTAssertEqual(Socks5Address.domain("example.com").displayValue, "example.com")
    }

    func testUpstreamErrorsMapToSpecificReplies() {
        XCTAssertEqual(Socks5Reply.forUpstreamError(.posix(.ECONNREFUSED)), .connectionRefused)
        XCTAssertEqual(Socks5Reply.forUpstreamError(.posix(.ENETUNREACH)), .networkUnreachable)
        XCTAssertEqual(Socks5Reply.forUpstreamError(.posix(.EHOSTUNREACH)), .hostUnreachable)
        XCTAssertEqual(Socks5Reply.forUpstreamError(.posix(.ECONNRESET)), .generalFailure)
    }
}
