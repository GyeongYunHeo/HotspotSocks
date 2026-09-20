import Foundation
import XCTest
@testable import HotspotSocks

final class ThermalStateTests: XCTestCase {
    func testThermalStateLabels() {
        XCTAssertEqual(ThermalLevel(.nominal), .nominal)
        XCTAssertEqual(ThermalLevel(.fair), .fair)
        XCTAssertEqual(ThermalLevel(.serious), .serious)
        XCTAssertEqual(ThermalLevel(.critical), .critical)
        XCTAssertEqual(ThermalLevel.critical.label, "매우 높음")
    }
}
