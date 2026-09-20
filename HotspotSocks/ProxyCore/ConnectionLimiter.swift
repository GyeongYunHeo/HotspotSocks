import Foundation

/// Enforces one application-wide connection ceiling across all proxy listeners.
final class ConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeConnections = 0

    func acquire(maximum: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < maximum else { return false }
        activeConnections += 1
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        activeConnections = max(0, activeConnections - 1)
    }
}
