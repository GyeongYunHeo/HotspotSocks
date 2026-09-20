import Foundation
import Network

enum UdpAssociationError: Error, LocalizedError, Sendable {
    case listenerFailed(String)
    case clientEndpointUnavailable
    case clientControlEndpointUnavailable
    case invalidClientEndpoint
    case idleTimeout

    var errorDescription: String? {
        switch self {
        case let .listenerFailed(message): "UDP listener failed: \(message)"
        case .clientEndpointUnavailable: "The UDP client endpoint is unavailable."
        case .clientControlEndpointUnavailable: "The TCP control endpoint is unavailable."
        case .invalidClientEndpoint: "A UDP datagram arrived from a client outside this association."
        case .idleTimeout: "The UDP association exceeded its idle timeout."
        }
    }
}

/// Owns one RFC 1928 UDP association and all bounded per-destination UDP flows.
final class UdpAssociation: @unchecked Sendable {
    typealias ReadyHandler = @Sendable (Socks5Address, UInt16) -> Void
    typealias ActivityHandler = @Sendable () -> Void
    typealias Completion = @Sendable (Error?) -> Void

    fileprivate struct EndpointIdentity: Hashable {
        enum Host: Hashable {
            case ipv4(Data)
            case ipv6(Data)
            case name(String)
        }

        let host: Host
        let port: UInt16
    }

    private struct UpstreamFlow {
        let connection: NWConnection
        var lastActivity: Date
        var isReady = false
        var pendingPayloads: [Data] = []
        var pendingByteCount = 0
    }

    private static let maximumPendingDatagramsPerDestination = 8
    private static let maximumPendingBytesPerDestination = 256 * 1_024
    private static let upstreamConnectionTimeout: TimeInterval = 20

    let identifier: UUID
    private let controlConnection: NWConnection
    private let requestedClientEndpoint: Socks5ConnectRequest
    private let queue: DispatchQueue
    private let egressMode: EgressMode
    private let idleTimeout: TimeInterval
    private let maximumDestinations: Int
    private let accessPolicy: AccessPolicy
    private let rejectionHandler: @Sendable () -> Void
    private let upstreamConnector: any UdpUpstreamConnecting
    private let readyHandler: ReadyHandler
    private let activityHandler: ActivityHandler
    private let uploadHandler: @Sendable (Int) -> Void
    private let downloadHandler: @Sendable (Int) -> Void
    private let completion: Completion
    private var listener: NWListener?
    private var clientConnection: NWConnection?
    private var clientEndpoint: EndpointIdentity?
    private var controlClientEndpoint: EndpointIdentity?
    private var upstreamFlows: [Socks5ConnectRequest: UpstreamFlow] = [:]
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = Date()
    private var lastIdleTimerScheduleDate: Date?
    private var lastFlowEvictionDate = Date.distantPast
    private var didFinish = false

    init(
        identifier: UUID = UUID(),
        controlConnection: NWConnection,
        requestedClientEndpoint: Socks5ConnectRequest,
        queue: DispatchQueue,
        egressMode: EgressMode,
        idleTimeout: TimeInterval,
        maximumDestinations: Int = 16,
        accessPolicy: AccessPolicy = AccessPolicy(allowPrivateNetworks: false),
        rejectionHandler: @escaping @Sendable () -> Void = {},
        upstreamConnector: any UdpUpstreamConnecting = UdpUpstreamConnector(),
        readyHandler: @escaping ReadyHandler,
        activityHandler: @escaping ActivityHandler,
        uploadHandler: @escaping @Sendable (Int) -> Void = { _ in },
        downloadHandler: @escaping @Sendable (Int) -> Void = { _ in },
        completion: @escaping Completion
    ) {
        self.identifier = identifier
        self.controlConnection = controlConnection
        self.requestedClientEndpoint = requestedClientEndpoint
        self.queue = queue
        self.egressMode = egressMode
        self.idleTimeout = idleTimeout
        self.maximumDestinations = maximumDestinations
        self.accessPolicy = accessPolicy
        self.rejectionHandler = rejectionHandler
        self.upstreamConnector = upstreamConnector
        self.readyHandler = readyHandler
        self.activityHandler = activityHandler
        self.uploadHandler = uploadHandler
        self.downloadHandler = downloadHandler
        self.completion = completion
    }

    func start() {
        guard !didFinish else { return }
        guard let controlEndpoint = endpointIdentity(from: controlConnection.endpoint) else {
            finish(UdpAssociationError.clientControlEndpointUnavailable)
            return
        }
        controlClientEndpoint = controlEndpoint

        do {
            let newListener = try NWListener(using: .udp, on: .any)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self, let newListener, listener === newListener, !didFinish else { return }
                switch state {
                case .ready:
                    listenerReady(newListener)
                case let .failed(error):
                    finish(UdpAssociationError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    if !didFinish { finish(nil) }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.acceptClient(connection)
            }
            startIdleTimer()
            newListener.start(queue: queue)
            AppLogger.udp.info("UDP association \(self.identifier.uuidString, privacy: .public) starting via \(self.egressMode.rawValue, privacy: .public)")
        } catch {
            finish(error)
        }
    }

    func cancel() {
        finish(nil)
    }

    private func listenerReady(_ listener: NWListener) {
        guard let port = listener.port?.rawValue,
              let localEndpoint = controlConnection.currentPath?.localEndpoint,
              case let .hostPort(host, _) = localEndpoint,
              let address = socksAddress(from: host) else {
            finish(UdpAssociationError.clientEndpointUnavailable)
            return
        }
        AppLogger.udp.info("UDP association \(self.identifier.uuidString, privacy: .public) ready on \(address.displayValue, privacy: .public):\(port, privacy: .public)")
        readyHandler(address, port)
    }

    private func acceptClient(_ connection: NWConnection) {
        guard !didFinish, let endpoint = endpointIdentity(from: connection.endpoint) else {
            connection.cancel()
            return
        }
        guard isPermittedClient(endpoint) else {
            rejectionHandler()
            AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) rejected client \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        guard clientConnection == nil else {
            connection.cancel()
            return
        }

        clientEndpoint = endpoint
        clientConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, clientConnection === connection, !didFinish else { return }
            switch state {
            case .ready:
                AppLogger.udp.info("UDP association \(self.identifier.uuidString, privacy: .public) learned client \(String(describing: connection.endpoint), privacy: .public)")
                receiveClientDatagram(on: connection)
            case let .failed(error):
                finish(error)
            case .cancelled:
                if !didFinish { finish(nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveClientDatagram(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection, clientConnection === connection, !didFinish else { return }
            if let error {
                finish(error)
                return
            }
            if let content {
                recordActivity()
                handleClientDatagram(content)
            }
            receiveClientDatagram(on: connection)
        }
    }

    private func handleClientDatagram(_ content: Data) {
        do {
            let datagram = try Socks5UdpCodec.parse(content)
            let decision = accessPolicy.evaluate(destination: datagram.destination.address)
            guard decision == .allowed else {
                rejectionHandler()
                AppLogger.security.error("UDP association \(self.identifier.uuidString, privacy: .public) blocked destination \(datagram.destination.address.displayValue, privacy: .public):\(datagram.destination.port, privacy: .public): \(String(describing: decision), privacy: .public)")
                return
            }
            uploadHandler(datagram.payload.count)
            evictIdleUpstreamFlows()
            send(datagram.payload, to: datagram.destination)
        } catch let error as Socks5UdpDatagramError {
            rejectionHandler()
            AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) dropped malformed datagram: \(error.localizedDescription, privacy: .public)")
        } catch {
            rejectionHandler()
            AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) dropped datagram: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func send(_ payload: Data, to destination: Socks5ConnectRequest) {
        if var flow = upstreamFlows[destination] {
            flow.lastActivity = Date()
            if flow.isReady {
                upstreamFlows[destination] = flow
                sendPayload(payload, on: flow.connection, to: destination)
            } else if enqueue(payload, in: &flow, destination: destination) {
                upstreamFlows[destination] = flow
            }
            return
        }

        if upstreamFlows.count >= maximumDestinations {
            evictOldestUpstreamFlow()
        }
        let connection: NWConnection
        do {
            connection = try upstreamConnector.makeConnection(to: destination, egressMode: egressMode)
        } catch {
            AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) could not create upstream \(destination.address.displayValue, privacy: .public):\(destination.port, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        var flow = UpstreamFlow(connection: connection, lastActivity: Date())
        _ = enqueue(payload, in: &flow, destination: destination)
        upstreamFlows[destination] = flow
        configureUpstream(connection, for: destination)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.upstreamConnectionTimeout) { [weak self, weak connection] in
            guard let self, let connection,
                  let flow = upstreamFlows[destination],
                  flow.connection === connection,
                  !flow.isReady else { return }
            AppLogger.security.notice("UDP association \(self.identifier.uuidString, privacy: .public) upstream connection deadline expired for \(destination.address.displayValue, privacy: .public)")
            removeUpstream(connection, for: destination)
        }
    }

    private func sendPayload(
        _ payload: Data,
        on connection: NWConnection,
        to destination: Socks5ConnectRequest
    ) {
        connection.send(
            content: payload,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, !didFinish else { return }
                if let error {
                    AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) upstream send failed: \(error.localizedDescription, privacy: .public)")
                    removeUpstream(connection, for: destination)
                } else {
                    recordActivity()
                }
            }
        )
    }

    private func enqueue(
        _ payload: Data,
        in flow: inout UpstreamFlow,
        destination: Socks5ConnectRequest
    ) -> Bool {
        guard flow.pendingPayloads.count < Self.maximumPendingDatagramsPerDestination,
              flow.pendingByteCount <= Self.maximumPendingBytesPerDestination - payload.count else {
            rejectionHandler()
            AppLogger.security.error("UDP association \(self.identifier.uuidString, privacy: .public) dropped pending datagram for \(destination.address.displayValue, privacy: .public): per-destination pending limit reached")
            return false
        }
        flow.pendingPayloads.append(payload)
        flow.pendingByteCount += payload.count
        return true
    }

    private func configureUpstream(_ connection: NWConnection, for destination: Socks5ConnectRequest) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, isCurrent(connection, for: destination), !didFinish else { return }
            switch state {
            case .ready:
                let decision = accessPolicy.evaluate(remoteEndpoint: connection.currentPath?.remoteEndpoint)
                    ?? accessPolicy.evaluate(destination: destination.address)
                guard decision == .allowed else {
                    rejectionHandler()
                    AppLogger.security.error("UDP association \(self.identifier.uuidString, privacy: .public) blocked resolved upstream endpoint: \(String(describing: decision), privacy: .public)")
                    removeUpstream(connection, for: destination)
                    return
                }
                guard var flow = upstreamFlows[destination], flow.connection === connection else { return }
                let pendingPayloads = flow.pendingPayloads
                flow.pendingPayloads.removeAll(keepingCapacity: false)
                flow.pendingByteCount = 0
                flow.isReady = true
                upstreamFlows[destination] = flow
                let cellular = connection.currentPath?.usesInterfaceType(.cellular) ?? false
                AppLogger.udp.info("UDP association \(self.identifier.uuidString, privacy: .public) upstream ready for \(destination.address.displayValue, privacy: .public):\(destination.port, privacy: .public) via \(self.egressMode.rawValue, privacy: .public), cellular path: \(cellular, privacy: .public)")
                receiveUpstreamDatagram(on: connection, from: destination)
                for payload in pendingPayloads {
                    sendPayload(payload, on: connection, to: destination)
                }
            case let .waiting(error):
                AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) upstream waiting via \(self.egressMode.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if egressMode == .cellularOnly {
                    removeUpstream(connection, for: destination)
                }
            case let .failed(error):
                AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) upstream failed: \(error.localizedDescription, privacy: .public)")
                removeUpstream(connection, for: destination)
            case .cancelled:
                removeUpstream(connection, for: destination, cancel: false)
            default:
                break
            }
        }
    }

    private func receiveUpstreamDatagram(
        on connection: NWConnection,
        from destination: Socks5ConnectRequest
    ) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection, isCurrent(connection, for: destination), !didFinish else { return }
            if let error {
                AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) upstream receive failed: \(error.localizedDescription, privacy: .public)")
                removeUpstream(connection, for: destination)
                return
            }
            if let content {
                touchUpstreamFlow(connection, for: destination)
                recordActivity()
                downloadHandler(content.count)
                sendToClient(content, from: responseSource(for: connection, fallback: destination))
            }
            receiveUpstreamDatagram(on: connection, from: destination)
        }
    }

    private func sendToClient(_ payload: Data, from source: Socks5ConnectRequest) {
        guard let clientConnection else { return }
        do {
            let response = try Socks5UdpCodec.encapsulate(
                payload: payload,
                sourceAddress: source.address,
                sourcePort: source.port
            )
            clientConnection.send(
                content: response,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self, !didFinish else { return }
                    if let error {
                        finish(error)
                    } else {
                        recordActivity()
                    }
                }
            )
        } catch {
            AppLogger.udp.error("UDP association \(self.identifier.uuidString, privacy: .public) response encapsulation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func responseSource(
        for connection: NWConnection,
        fallback: Socks5ConnectRequest
    ) -> Socks5ConnectRequest {
        guard let remoteEndpoint = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, port) = remoteEndpoint,
              let address = socksAddress(from: host) else {
            return fallback
        }
        return Socks5ConnectRequest(address: address, port: port.rawValue)
    }

    private func isPermittedClient(_ candidate: EndpointIdentity) -> Bool {
        guard let controlClientEndpoint, candidate.host == controlClientEndpoint.host else { return false }
        if requestedClientEndpoint.port != 0, candidate.port != requestedClientEndpoint.port { return false }
        if !requestedClientEndpoint.address.isUnspecified,
           requestedClientEndpoint.address.endpointHostIdentity != candidate.host {
            return false
        }
        return clientEndpoint == nil || clientEndpoint == candidate
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.idleTimerFired()
        }
        idleTimer = timer
        recordActivity()
        timer.resume()
    }

    private func recordActivity() {
        let now = Date()
        lastActivity = now
        let refreshInterval = min(5, max(0.25, idleTimeout / 4))
        if let lastIdleTimerScheduleDate,
           now.timeIntervalSince(lastIdleTimerScheduleDate) < refreshInterval {
            activityHandler()
            return
        }
        lastIdleTimerScheduleDate = now
        idleTimer?.schedule(deadline: .now() + idleTimeout, leeway: .seconds(1))
        activityHandler()
    }

    private func idleTimerFired() {
        guard !didFinish else { return }
        let remaining = idleTimeout - Date().timeIntervalSince(lastActivity)
        guard remaining <= 0 else {
            lastIdleTimerScheduleDate = Date()
            idleTimer?.schedule(deadline: .now() + remaining, leeway: .seconds(1))
            return
        }
        finish(UdpAssociationError.idleTimeout)
    }

    private func evictIdleUpstreamFlows(now: Date = Date()) {
        let destinationIdleTimeout = min(120, idleTimeout)
        let scanInterval = min(10, max(0.25, destinationIdleTimeout / 4))
        guard now.timeIntervalSince(lastFlowEvictionDate) >= scanInterval else { return }
        lastFlowEvictionDate = now
        let expired = upstreamFlows.filter {
            now.timeIntervalSince($0.value.lastActivity) >= destinationIdleTimeout
        }
        for (destination, flow) in expired {
            removeUpstream(flow.connection, for: destination)
        }
    }

    private func evictOldestUpstreamFlow() {
        guard let oldest = upstreamFlows.min(by: { $0.value.lastActivity < $1.value.lastActivity }) else { return }
        removeUpstream(oldest.value.connection, for: oldest.key)
    }

    private func isCurrent(_ connection: NWConnection, for destination: Socks5ConnectRequest) -> Bool {
        upstreamFlows[destination]?.connection === connection
    }

    private func touchUpstreamFlow(_ connection: NWConnection, for destination: Socks5ConnectRequest) {
        guard var flow = upstreamFlows[destination], flow.connection === connection else { return }
        flow.lastActivity = Date()
        upstreamFlows[destination] = flow
    }

    private func removeUpstream(
        _ connection: NWConnection,
        for destination: Socks5ConnectRequest,
        cancel: Bool = true
    ) {
        guard isCurrent(connection, for: destination) else { return }
        upstreamFlows.removeValue(forKey: destination)
        if cancel { connection.cancel() }
    }

    private func finish(_ error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        idleTimer?.cancel()
        idleTimer = nil
        lastIdleTimerScheduleDate = nil
        listener?.cancel()
        listener = nil
        clientConnection?.cancel()
        clientConnection = nil
        let connections = upstreamFlows.values.map(\.connection)
        upstreamFlows.removeAll()
        connections.forEach { $0.cancel() }
        AppLogger.udp.info("UDP association \(self.identifier.uuidString, privacy: .public) closed: \(error?.localizedDescription ?? "normal", privacy: .public)")
        completion(error)
    }

    private func endpointIdentity(from endpoint: NWEndpoint) -> EndpointIdentity? {
        guard case let .hostPort(host, port) = endpoint,
              let identity = host.endpointIdentity else { return nil }
        return EndpointIdentity(host: identity, port: port.rawValue)
    }

    private func socksAddress(from host: NWEndpoint.Host) -> Socks5Address? {
        switch host {
        case let .ipv4(address): .ipv4(Array(address.rawValue))
        case let .ipv6(address):
            if case let .ipv4(bytes) = normalizedIdentity(for: address.rawValue) {
                .ipv4(Array(bytes))
            } else {
                .ipv6(Array(address.rawValue))
            }
        case let .name(name, _): .domain(name)
        @unknown default: nil
        }
    }
}

private extension NWEndpoint.Host {
    var endpointIdentity: UdpAssociation.EndpointIdentity.Host? {
        switch self {
        case let .ipv4(address): .ipv4(address.rawValue)
        case let .ipv6(address): normalizedIdentity(for: address.rawValue)
        case let .name(name, _): .name(name.lowercased())
        @unknown default: nil
        }
    }
}

private extension Socks5Address {
    var isUnspecified: Bool {
        switch self {
        case let .ipv4(bytes): bytes.count == 4 && bytes.allSatisfy { $0 == 0 }
        case let .ipv6(bytes): bytes.count == 16 && bytes.allSatisfy { $0 == 0 }
        case .domain: false
        }
    }

    var endpointHostIdentity: UdpAssociation.EndpointIdentity.Host? {
        switch self {
        case let .ipv4(bytes) where bytes.count == 4: .ipv4(Data(bytes))
        case let .ipv6(bytes) where bytes.count == 16: normalizedIdentity(for: Data(bytes))
        case let .domain(name): .name(name.lowercased())
        default: nil
        }
    }
}

private func normalizedIdentity(for ipv6Bytes: Data) -> UdpAssociation.EndpointIdentity.Host {
    let bytes = Array(ipv6Bytes)
    if bytes.count == 16,
       bytes.prefix(10).allSatisfy({ $0 == 0 }),
       bytes[10] == 0xFF,
       bytes[11] == 0xFF {
        return .ipv4(Data(bytes[12..<16]))
    }
    return .ipv6(ipv6Bytes)
}
