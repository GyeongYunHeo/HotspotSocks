import XCTest
@testable import HotspotSocks

final class TrafficStatisticsTests: XCTestCase {
    func testConnectionAndTrafficCounters() {
        let statistics = TrafficStatistics()
        let startDate = Date(timeIntervalSince1970: 1_000)

        statistics.reset(startDate: startDate)
        statistics.connectionAccepted()
        statistics.connectionAccepted()
        statistics.recordUpload(123)
        statistics.recordDownload(456)
        statistics.connectionClosed()
        statistics.connectionRejected()

        XCTAssertEqual(
            statistics.snapshot(),
            TrafficStatisticsSnapshot(
                activeConnections: 1,
                totalConnections: 2,
                bytesUploaded: 123,
                bytesDownloaded: 456,
                serverStartDate: startDate,
                rejectedConnections: 1
            )
        )
    }

    func testCountersNeverUnderflow() {
        let statistics = TrafficStatistics()
        statistics.connectionClosed()
        statistics.recordUpload(0)
        statistics.recordDownload(-1)

        XCTAssertEqual(statistics.snapshot().activeConnections, 0)
        XCTAssertEqual(statistics.snapshot().bytesUploaded, 0)
        XCTAssertEqual(statistics.snapshot().bytesDownloaded, 0)
    }

    func testResetStartsNewServerSession() {
        let statistics = TrafficStatistics()
        statistics.reset(startDate: .distantPast)
        statistics.connectionAccepted()
        statistics.recordUpload(10)

        let newStartDate = Date(timeIntervalSince1970: 2_000)
        statistics.reset(startDate: newStartDate)

        XCTAssertEqual(
            statistics.snapshot(),
            TrafficStatisticsSnapshot(serverStartDate: newStartDate)
        )
    }
}
