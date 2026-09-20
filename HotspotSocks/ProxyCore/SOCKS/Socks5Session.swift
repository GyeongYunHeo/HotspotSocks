import Foundation
import Network

enum Socks5SessionState: String, Sendable {
    case greeting, request, connecting, relaying, associatingUDP, relayingUDP, closing, closed
}

final class Socks5Session: @unchecked Sendable {
    typealias Completion = @Sendable () -> Void
    private static let maximumHandshakeReceiveLength = 64 * 1_024
    private static let upstreamConnectionTimeout: TimeInterval = 20

    let identifier: UUID
    private let client: NWConnection
    private let queue: DispatchQueue
    private let upstreamConnector: any UpstreamConnecting
    private let egressMode: EgressMode
    private let idleTimeout: TimeInterval
    private let handshakeTimeout: TimeInterval
    private let accessPolicy: AccessPolicy
    private let rejectionHandler: @Sendable () -> Void
    private let uploadHandler: @Sendable (Int) -> Void
    private let downloadHandler: @Sendable (Int) -> Void
    private let completion: Completion
    private var parser = Socks5Parser()
    private var state: Socks5SessionState = .greeting
    private var upstream: NWConnection?
    private var relay: RelayPipe?
    private var udpAssociation: UdpAssociation?
    private var idleTimer: DispatchSourceTimer?
    private var handshakeTimer: DispatchSourceTimer?
    private var upstreamTimer: DispatchSourceTimer?
    private var lastActivity = Date()
    private var lastIdleTimerScheduleDate: Date?
    private var clientInputComplete = false
    private var didFinish = false

    init(
        identifier: UUID = UUID(),
        client: NWConnection,
        queue: DispatchQueue,
        upstreamConnector: any UpstreamConnecting = UpstreamConnector(),
        egressMode: EgressMode = .systemDefault,
        idleTimeout: TimeInterval = 1_800,
        handshakeTimeout: TimeInterval = 15,
        accessPolicy: AccessPolicy = AccessPolicy(allowPrivateNetworks: false),
        rejectionHandler: @escaping @Sendable () -> Void = {},
        uploadHandler: @escaping @Sendable (Int) -> Void = { _ in },
        downloadHandler: @escaping @Sendable (Int) -> Void = { _ in },
        completion: @escaping Completion
    ) {
        self.identifier = identifier
        self.client = client
        self.queue = queue
        self.upstreamConnector = upstreamConnector
        self.egressMode = egressMode
        self.idleTimeout = idleTimeout
        self.handshakeTimeout = handshakeTimeout
        self.accessPolicy = accessPolicy
        self.rejectionHandler = rejectionHandler
        self.uploadHandler = uploadHandler
        self.downloadHandler = downloadHandler
        self.completion = completion
    }

    func start() {
        startIdleTimer()
        startHandshakeTimer()
        client.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .ready:
                AppLogger.socks.info("Session \(self.identifier.uuidString, privacy: .public) client ready")
                receiveHandshake()
            case let .failed(error):
                AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) client failed: \(error.localizedDescription, privacy: .public)")
                if state != .relaying { finish() }
            case .cancelled:
                if state != .relaying { finish() }
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    func stop() {
        finish()
    }

    private func receiveHandshake() {
        guard state == .greeting || state == .request else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHandshakeReceiveLength) {
            [weak self] content, _, isComplete, error in
            guard let self, !didFinish else { return }
            if let error {
                AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) receive failed: \(error.localizedDescription, privacy: .public)")
                finish()
                return
            }
            guard let content, !content.isEmpty else {
                if isComplete { fail(Socks5Error.connectionClosed) }
                else { receiveHandshake() }
                return
            }
            if isComplete { clientInputComplete = true }
            recordActivity()
            do {
                let messages = try parser.append(content)
                process(messages[...])
            } catch {
                let precedingMessages = parser.takeMessagesBeforeFailure()
                if precedingMessages.isEmpty {
                    handleParserError(error)
                } else {
                    process(precedingMessages[...], terminalError: error)
                }
            }
        }
    }

    private func process(_ messages: ArraySlice<Socks5Message>, terminalError: Error? = nil) {
        guard let message = messages.first else {
            if let terminalError { handleParserError(terminalError) }
            else { receiveHandshake() }
            return
        }
        switch message {
        case let .greeting(methods):
            guard state == .greeting else { fail(Socks5Error.unexpectedMessage); return }
            guard methods.contains(Socks5Protocol.noAuthentication) else {
                rejectionHandler()
                send(Data([Socks5Protocol.version, Socks5Protocol.noAcceptableMethods])) { [weak self] in self?.finish() }
                return
            }
            send(Data([Socks5Protocol.version, Socks5Protocol.noAuthentication])) { [weak self] in
                guard let self else { return }
                transition(to: .request)
                process(messages.dropFirst(), terminalError: terminalError)
            }
        case let .connectRequest(request):
            guard state == .request else { fail(Socks5Error.unexpectedMessage); return }
            cancelHandshakeTimer()
            guard accessPolicy.evaluate(destination: request.address) == .allowed else {
                rejectDestination(request)
                return
            }
            transition(to: .connecting)
            connectUpstream(for: request)
        case let .udpAssociateRequest(request):
            guard state == .request else { fail(Socks5Error.unexpectedMessage); return }
            cancelHandshakeTimer()
            transition(to: .associatingUDP)
            startUdpAssociation(for: request)
        }
    }

    private func startUdpAssociation(for request: Socks5ConnectRequest) {
        let associationID = UUID()
        let association = UdpAssociation(
            identifier: associationID,
            controlConnection: client,
            requestedClientEndpoint: request,
            queue: queue,
            egressMode: egressMode,
            idleTimeout: idleTimeout,
            accessPolicy: accessPolicy,
            rejectionHandler: rejectionHandler,
            readyHandler: { [weak self] address, port in
                self?.udpAssociationReady(id: associationID, address: address, port: port)
            },
            activityHandler: { [weak self] in
                self?.recordActivity()
            },
            uploadHandler: uploadHandler,
            downloadHandler: downloadHandler,
            completion: { [weak self] error in
                self?.udpAssociationEnded(id: associationID, error: error)
            }
        )
        udpAssociation = association
        association.start()
    }

    private func udpAssociationReady(id: UUID, address: Socks5Address, port: UInt16) {
        guard state == .associatingUDP, udpAssociation?.identifier == id else { return }
        do {
            let response = try Socks5Reply.succeeded.responseData(boundAddress: address, boundPort: port)
            send(response) { [weak self] in
                guard let self, state == .associatingUDP else { return }
                transition(to: .relayingUDP)
                let unexpectedControlData = parser.takeRemainingData()
                if !unexpectedControlData.isEmpty {
                    AppLogger.udp.warning("Session \(self.identifier.uuidString, privacy: .public) discarded \(unexpectedControlData.count, privacy: .public) bytes after UDP ASSOCIATE")
                }
                if clientInputComplete {
                    finish()
                } else {
                    receiveUdpControlChannel()
                }
            }
        } catch {
            AppLogger.udp.error("Session \(self.identifier.uuidString, privacy: .public) could not encode UDP ASSOCIATE reply: \(error.localizedDescription, privacy: .public)")
            sendReplyAndFinish(.generalFailure)
        }
    }

    private func receiveUdpControlChannel() {
        guard state == .relayingUDP else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
            [weak self] content, _, isComplete, error in
            guard let self, !didFinish else { return }
            if let error {
                AppLogger.udp.error("Session \(self.identifier.uuidString, privacy: .public) UDP control channel failed: \(error.localizedDescription, privacy: .public)")
                finish()
                return
            }
            if let content, !content.isEmpty {
                recordActivity()
                AppLogger.udp.warning("Session \(self.identifier.uuidString, privacy: .public) ignored \(content.count, privacy: .public) unexpected UDP control bytes")
            }
            if isComplete {
                AppLogger.udp.info("Session \(self.identifier.uuidString, privacy: .public) UDP control channel closed")
                finish()
            } else {
                receiveUdpControlChannel()
            }
        }
    }

    private func udpAssociationEnded(id: UUID, error: Error?) {
        guard udpAssociation?.identifier == id else { return }
        udpAssociation = nil
        guard !didFinish else { return }
        if let error {
            AppLogger.udp.error("Session \(self.identifier.uuidString, privacy: .public) UDP association ended: \(error.localizedDescription, privacy: .public)")
        }
        if state == .associatingUDP {
            sendReplyAndFinish(.generalFailure)
        } else {
            finish()
        }
    }

    private func connectUpstream(for request: Socks5ConnectRequest) {
        do {
            let connection = try upstreamConnector.makeConnection(to: request, egressMode: egressMode)
            upstream = connection
            AppLogger.socks.info("Session \(self.identifier.uuidString, privacy: .public) connecting to \(request.address.displayValue, privacy: .public):\(request.port, privacy: .public) via \(self.egressMode.rawValue, privacy: .public)")
            connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
                guard let self, let connection, !didFinish else { return }
                switch connectionState {
                case .ready:
                    cancelUpstreamTimer()
                    upstreamReady(connection)
                case let .failed(error):
                    cancelUpstreamTimer()
                    AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) upstream failed: \(error.localizedDescription, privacy: .public)")
                    if state == .connecting {
                        sendReplyAndFinish(Socks5Reply.forUpstreamError(error))
                    }
                case let .waiting(error):
                    AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) upstream waiting in \(self.egressMode.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if state == .connecting && egressMode == .cellularOnly {
                        sendReplyAndFinish(.networkUnreachable)
                    }
                case .cancelled:
                    if state == .connecting { finish() }
                default:
                    break
                }
            }
            startUpstreamTimer()
            connection.start(queue: queue)
        } catch {
            AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) upstream creation failed: \(error.localizedDescription, privacy: .public)")
            sendReplyAndFinish(.generalFailure)
        }
    }

    private func upstreamReady(_ connection: NWConnection) {
        guard state == .connecting else { return }
        if let decision = accessPolicy.evaluate(remoteEndpoint: connection.currentPath?.remoteEndpoint),
           decision != .allowed {
            AppLogger.security.error("Session \(self.identifier.uuidString, privacy: .public) blocked resolved upstream endpoint: \(String(describing: decision), privacy: .public)")
            rejectionHandler()
            sendReplyAndFinish(.connectionNotAllowed)
            return
        }
        recordActivity()
        let usesCellular = connection.currentPath?.usesInterfaceType(.cellular) ?? false
        AppLogger.socks.info("Session \(self.identifier.uuidString, privacy: .public) upstream ready via \(self.egressMode.rawValue, privacy: .public), cellular path: \(usesCellular, privacy: .public)")
        send(Socks5Reply.succeeded.responseData) { [weak self, weak connection] in
            guard let self, let connection, !didFinish else { return }
            transition(to: .relaying)
            let initialUpload = parser.takeRemainingData()
            let newRelay = RelayPipe(
                client: client,
                upstream: connection,
                activityHandler: { [weak self] in self?.recordActivity() },
                uploadHandler: uploadHandler,
                downloadHandler: downloadHandler
            ) { [weak self] result in
                if case let .failure(error) = result {
                    AppLogger.relay.error("Session \(self?.identifier.uuidString ?? "unknown", privacy: .public) relay failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.finish()
            }
            relay = newRelay
            newRelay.start(
                initialUpload: initialUpload,
                uploadIsComplete: clientInputComplete
            )
        }
    }

    private func handleParserError(_ error: Error) {
        AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) rejected handshake: \(error.localizedDescription, privacy: .public)")
        rejectionHandler()
        switch error {
        case Socks5Error.unsupportedCommand:
            sendReplyAndFinish(.commandNotSupported)
        case Socks5Error.unsupportedAddressType:
            sendReplyAndFinish(.addressTypeNotSupported)
        default:
            finish()
        }
    }

    private func rejectDestination(_ request: Socks5ConnectRequest) {
        let decision = accessPolicy.evaluate(destination: request.address)
        AppLogger.security.error("Session \(self.identifier.uuidString, privacy: .public) blocked destination \(request.address.displayValue, privacy: .public):\(request.port, privacy: .public): \(String(describing: decision), privacy: .public)")
        rejectionHandler()
        sendReplyAndFinish(.connectionNotAllowed)
    }

    private func sendReplyAndFinish(_ reply: Socks5Reply) {
        send(reply.responseData) { [weak self] in self?.finish() }
    }

    private func send(_ data: Data, then completion: @escaping @Sendable () -> Void) {
        client.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) send failed: \(error.localizedDescription, privacy: .public)")
                finish()
            } else {
                recordActivity()
                completion()
            }
        })
    }

    private func fail(_ error: Error) {
        AppLogger.socks.error("Session \(self.identifier.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        finish()
    }

    private func transition(to newState: Socks5SessionState) {
        AppLogger.socks.debug("Session \(self.identifier.uuidString, privacy: .public): \(self.state.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public)")
        state = newState
    }

    private func startIdleTimer() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.idleTimerFired()
        }
        idleTimer = timer
        recordActivity()
        timer.resume()
    }

    private func startHandshakeTimer() {
        guard handshakeTimer == nil, handshakeTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + handshakeTimeout, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, state == .greeting || state == .request else { return }
            AppLogger.security.notice("Session \(self.identifier.uuidString, privacy: .public) exceeded the \(self.handshakeTimeout, privacy: .public)-second handshake deadline")
            fail(Socks5Error.handshakeTimeout)
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func cancelHandshakeTimer() {
        handshakeTimer?.setEventHandler {}
        handshakeTimer?.cancel()
        handshakeTimer = nil
    }

    private func startUpstreamTimer() {
        cancelUpstreamTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.upstreamConnectionTimeout,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            guard let self, state == .connecting else { return }
            AppLogger.security.notice("Session \(self.identifier.uuidString, privacy: .public) upstream connection deadline expired")
            sendReplyAndFinish(.hostUnreachable)
        }
        upstreamTimer = timer
        timer.resume()
    }

    private func cancelUpstreamTimer() {
        upstreamTimer?.setEventHandler {}
        upstreamTimer?.cancel()
        upstreamTimer = nil
    }

    private func recordActivity() {
        let now = Date()
        lastActivity = now
        let refreshInterval = min(5, max(0.25, idleTimeout / 4))
        if let lastIdleTimerScheduleDate,
           now.timeIntervalSince(lastIdleTimerScheduleDate) < refreshInterval {
            return
        }
        lastIdleTimerScheduleDate = now
        idleTimer?.schedule(
            deadline: .now() + idleTimeout,
            leeway: .seconds(1)
        )
    }

    private func idleTimerFired() {
        guard !didFinish else { return }
        let remaining = idleTimeout - Date().timeIntervalSince(lastActivity)
        guard remaining <= 0 else {
            lastIdleTimerScheduleDate = Date()
            idleTimer?.schedule(
                deadline: .now() + remaining,
                leeway: .seconds(1)
            )
            return
        }
        AppLogger.socks.notice("Session \(self.identifier.uuidString, privacy: .public) idle timeout after \(self.idleTimeout, privacy: .public) seconds")
        fail(Socks5Error.idleTimeout)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        transition(to: .closing)
        idleTimer?.setEventHandler {}
        idleTimer?.cancel()
        idleTimer = nil
        lastIdleTimerScheduleDate = nil
        cancelHandshakeTimer()
        cancelUpstreamTimer()
        relay?.cancel()
        relay = nil
        udpAssociation?.cancel()
        udpAssociation = nil
        upstream?.cancel()
        upstream = nil
        client.cancel()
        transition(to: .closed)
        completion()
    }
}
