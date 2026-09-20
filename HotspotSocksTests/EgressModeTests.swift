import Network
import XCTest
@testable import HotspotSocks

final class EgressModeTests: XCTestCase {
    func testSystemDefaultDoesNotRequireAnInterface() {
        XCTAssertNil(EgressMode.systemDefault.requiredInterfaceType)
    }

    func testCellularOnlyRequiresCellularWithoutFallback() {
        XCTAssertEqual(EgressMode.cellularOnly.requiredInterfaceType, .cellular)
        XCTAssertEqual(
            UpstreamConnector().makeParameters(for: .cellularOnly).requiredInterfaceType,
            .cellular
        )
        XCTAssertEqual(
            UdpUpstreamConnector().makeParameters(for: .cellularOnly).requiredInterfaceType,
            .cellular
        )
    }

    func testLabelsAndCasesRemainStableForSettingsUI() {
        XCTAssertEqual(EgressMode.allCases, [.systemDefault, .cellularOnly])
        XCTAssertEqual(EgressMode.systemDefault.label, "자동")
        XCTAssertEqual(EgressMode.cellularOnly.label, "셀룰러 전용")
    }
}
