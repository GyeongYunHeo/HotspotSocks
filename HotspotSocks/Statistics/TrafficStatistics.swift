import Foundation

struct TrafficStatisticsSnapshot: Equatable, Sendable {
    var activeConnections = 0
    var totalConnections = 0
    var bytesUploaded: UInt64 = 0
    var bytesDownloaded: UInt64 = 0
    var serverStartDate: Date?
    var rejectedConnections = 0
}

/// Lock-protected event counters. UI publication is coalesced by ProxyServer.
final class TrafficStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TrafficStatisticsSnapshot()

    func reset(startDate: Date) {
        withLock {
            value = TrafficStatisticsSnapshot(serverStartDate: startDate)
        }
    }

    func connectionAccepted() {
        withLock {
            value.activeConnections += 1
            value.totalConnections += 1
        }
    }

    func connectionClosed() {
        withLock {
            value.activeConnections = max(0, value.activeConnections - 1)
        }
    }

    func connectionRejected() {
        withLock {
            value.rejectedConnections += 1
        }
    }

    func recordUpload(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        withLock {
            value.bytesUploaded &+= UInt64(byteCount)
        }
    }

    func recordDownload(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        withLock {
            value.bytesDownloaded &+= UInt64(byteCount)
        }
    }

    func snapshot() -> TrafficStatisticsSnapshot {
        withLock { value }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
