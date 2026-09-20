import Foundation
import Network

enum ProxyState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "중지됨"
        case .starting: "시작 중"
        case .ready: "실행 중"
        case .stopping: "종료 중"
        case let .failed(message): "실패: \(message)"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum ProxyServerError: LocalizedError, Equatable {
    case invalidPort
    case invalidMaximumClients
    case invalidIdleTimeout

    var errorDescription: String? {
        switch self {
        case .invalidPort: "수신 포트는 1에서 65535 사이여야 합니다."
        case .invalidMaximumClients: "최대 연결 수는 1 이상이어야 합니다."
        case .invalidIdleTimeout: "유휴 연결 종료 시간은 0보다 커야 합니다."
        }
    }
}

/// Owns the TCP listener and active SOCKS5 session registry.
final class ProxyServer: @unchecked Sendable {
    typealias StateHandler = @Sendable (ProxyState) -> Void
    typealias StatisticsHandler = @Sendable (TrafficStatisticsSnapshot) -> Void

    private let queue = DispatchQueue(label: "com.example.HotspotSocks.server")
    private let stateHandler: StateHandler
    private let statisticsHandler: StatisticsHandler
    private let connectionLimiter: ConnectionLimiter
    private let statistics = TrafficStatistics()
    private var listener: NWListener?
    private var sessions: [UUID: Socks5Session] = [:]
    private var maximumClients = 128
    private var egressMode: EgressMode = .systemDefault
    private var idleTimeout: TimeInterval = 1_800
    private var accessPolicy = AccessPolicy(allowPrivateNetworks: false)
    private var statisticsUpdateScheduled = false
    private var statisticsUpdateGeneration: UInt64 = 0

    init(
        stateHandler: @escaping StateHandler,
        statisticsHandler: @escaping StatisticsHandler = { _ in },
        connectionLimiter: ConnectionLimiter = ConnectionLimiter()
    ) {
        self.stateHandler = stateHandler
        self.statisticsHandler = statisticsHandler
        self.connectionLimiter = connectionLimiter
    }

    func start(
        port: UInt16,
        maximumClients: Int,
        idleTimeout: TimeInterval,
        egressMode: EgressMode = .systemDefault,
        allowPrivateNetworks: Bool = false
    ) throws {
        guard port > 0, let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyServerError.invalidPort
        }
        guard maximumClients > 0 else { throw ProxyServerError.invalidMaximumClients }
        guard idleTimeout > 0, idleTimeout.isFinite else { throw ProxyServerError.invalidIdleTimeout }

        let newListener = try NWListener(using: .tcp, on: networkPort)
        queue.async { [weak self] in
            guard let self else { return }
            guard listener == nil else { return }

            self.maximumClients = maximumClients
            self.egressMode = egressMode
            self.idleTimeout = idleTimeout
            accessPolicy = AccessPolicy(allowPrivateNetworks: allowPrivateNetworks)
            statistics.reset(startDate: Date())
            listener = newListener
            stateHandler(.starting)
            publishStatisticsImmediately()
            configure(newListener)
            newListener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard listener != nil || !sessions.isEmpty else {
                stateHandler(.stopped)
                return
            }

            stateHandler(.stopping)
            listener?.cancel()
            listener = nil
            let activeSessions = Array(sessions.values)
            sessions.removeAll()
            activeSessions.forEach { $0.stop() }
            publishStatisticsImmediately()
            stateHandler(.stopped)
            AppLogger.server.info("Listener and all SOCKS5 sessions stopped")
        }
    }

    private func configure(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                stateHandler(.ready)
                if let port = listener.port?.rawValue {
                    AppLogger.server.info("SOCKS5 listener ready on port \(port, privacy: .public)")
                }
            case .failed(let error):
                AppLogger.server.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                self.listener = nil
                listener.cancel()
                let activeSessions = Array(sessions.values)
                sessions.removeAll()
                activeSessions.forEach { $0.stop() }
                publishStatisticsImmediately()
                stateHandler(.failed(error.localizedDescription))
            case .cancelled:
                self.listener = nil
                stateHandler(.stopped)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard accessPolicy.permitsClient(connection.endpoint) else {
            statistics.connectionRejected()
            scheduleStatisticsUpdate()
            AppLogger.security.error("Rejected non-local proxy client \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        guard connectionLimiter.acquire(maximum: maximumClients) else {
            statistics.connectionRejected()
            scheduleStatisticsUpdate()
            AppLogger.server.warning("Rejected connection because the \(self.maximumClients, privacy: .public)-client limit was reached")
            connection.cancel()
            return
        }

        let identifier = UUID()
        statistics.connectionAccepted()
        scheduleStatisticsUpdate()
        AppLogger.server.info("Accepted \(identifier.uuidString, privacy: .public) from \(String(describing: connection.endpoint), privacy: .public)")
        let session = Socks5Session(
            identifier: identifier,
            client: connection,
            queue: queue,
            egressMode: egressMode,
            idleTimeout: idleTimeout,
            accessPolicy: accessPolicy,
            rejectionHandler: { [weak self] in
                self?.statistics.connectionRejected()
                self?.scheduleStatisticsUpdate()
            },
            uploadHandler: { [weak self] byteCount in
                self?.statistics.recordUpload(byteCount)
                self?.scheduleStatisticsUpdate()
            },
            downloadHandler: { [weak self] byteCount in
                self?.statistics.recordDownload(byteCount)
                self?.scheduleStatisticsUpdate()
            }
        ) { [weak self] in
            guard let self else { return }
            sessions.removeValue(forKey: identifier)
            connectionLimiter.release()
            statistics.connectionClosed()
            scheduleStatisticsUpdate()
            AppLogger.server.info("Removed SOCKS5 session \(identifier.uuidString, privacy: .public)")
        }
        sessions[identifier] = session
        session.start()
    }

    private func scheduleStatisticsUpdate() {
        guard !statisticsUpdateScheduled else { return }
        statisticsUpdateScheduled = true
        statisticsUpdateGeneration &+= 1
        let generation = statisticsUpdateGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, generation == statisticsUpdateGeneration else { return }
            statisticsUpdateScheduled = false
            statisticsHandler(statistics.snapshot())
        }
    }

    private func publishStatisticsImmediately() {
        statisticsUpdateGeneration &+= 1
        statisticsUpdateScheduled = false
        statisticsHandler(statistics.snapshot())
    }
}
