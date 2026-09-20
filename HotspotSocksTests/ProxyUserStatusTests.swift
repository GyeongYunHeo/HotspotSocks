import XCTest
@testable import HotspotSocks

final class ProxyUserStatusTests: XCTestCase {
    func testServiceStatesMapToKoreanUserFacingStates() {
        XCTAssertEqual(ProxyUserStatus(serviceState: .stopped, activeConnections: 0), .off)
        XCTAssertEqual(ProxyUserStatus(serviceState: .starting, activeConnections: 0), .starting)
        XCTAssertEqual(ProxyUserStatus(serviceState: .ready, activeConnections: 0), .ready)
        XCTAssertEqual(ProxyUserStatus(serviceState: .ready, activeConnections: 1), .active)
        XCTAssertEqual(ProxyUserStatus(serviceState: .stopping, activeConnections: 0), .stopping)
        XCTAssertEqual(ProxyUserStatus(serviceState: .failed("기술 오류"), activeConnections: 0), .error)
    }

    func testPrimaryErrorCopyDoesNotExposeTechnicalDetail() {
        let status = ProxyUserStatus(serviceState: .failed("NWError 42"), activeConnections: 0)

        XCTAssertEqual(status.title, "오류")
        XCTAssertFalse(status.explanation.contains("NWError"))
    }
}
