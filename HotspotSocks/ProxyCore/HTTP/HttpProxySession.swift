import Foundation
import Network

private enum HttpProxySessionState {
    case readingRequest, connecting, relaying, closed
}

final class HttpProxySession: @unchecked Sendable {
    typealias Completion = @Sendable () -> Void
    private static let maximumReceiveLength = 64 * 1_024
    private static let upstreamConnectionTimeout: TimeInterval = 20

    let identifier: UUID
    private let client: NWConnection
    private let queue: DispatchQueue
    private let upstreamConnector: any UpstreamConnecting
    private let egressMode: EgressMode
    private let idleTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let accessPolicy: AccessPolicy
    private let pacFallbackHost: String?
    private let proxyPort: UInt16
    private let rejectionHandler: @Sendable () -> Void
    private let uploadHandler: @Sendable (Int) -> Void
    private let downloadHandler: @Sendable (Int) -> Void
    private let completion: Completion
    private var parser = HttpProxyParser()
    private var request: HttpProxyRequest?
    private var state: HttpProxySessionState = .readingRequest
    private var upstream: NWConnection?
    private var relay: RelayPipe?
    private var idleTimer: DispatchSourceTimer?
    private var requestTimer: DispatchSourceTimer?
    private var upstreamTimer: DispatchSourceTimer?
    private var lastActivity = Date()
    private var lastIdleTimerScheduleDate: Date?
    private var clientInputComplete = false
    private var isSendingTerminalResponse = false
    private var didFinish = false

    init(
        identifier: UUID = UUID(),
        client: NWConnection,
        queue: DispatchQueue,
        upstreamConnector: any UpstreamConnecting = UpstreamConnector(),
        egressMode: EgressMode = .systemDefault,
        idleTimeout: TimeInterval = 1_800,
        requestTimeout: TimeInterval = 15,
        accessPolicy: AccessPolicy = AccessPolicy(allowPrivateNetworks: false),
        pacFallbackHost: String? = nil,
        proxyPort: UInt16 = 9877,
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
        self.requestTimeout = requestTimeout
        self.accessPolicy = accessPolicy
        self.pacFallbackHost = pacFallbackHost
        self.proxyPort = proxyPort
        self.rejectionHandler = rejectionHandler
        self.uploadHandler = uploadHandler
        self.downloadHandler = downloadHandler
        self.completion = completion
    }

    func start() {
        startIdleTimer()
        startRequestTimer()
        client.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .ready: receiveRequest()
            case .failed, .cancelled:
                if state != .relaying { finish() }
            default: break
            }
        }
        client.start(queue: queue)
    }

    func stop() { finish() }

    private func receiveRequest() {
        guard state == .readingRequest else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReceiveLength) {
            [weak self] content, _, isComplete, error in
            guard let self, !didFinish else { return }
            if let error {
                AppLogger.http.error("HTTP session \(self.identifier.uuidString, privacy: .public) receive failed: \(error.localizedDescription, privacy: .public)")
                finish()
                return
            }
            if isComplete { clientInputComplete = true }
            guard let content, !content.isEmpty else {
                if isComplete { finish() } else { receiveRequest() }
                return
            }
            recordActivity()
            do {
                guard let initialRequest = try parser.append(content) else {
                    receiveRequest()
                    return
                }
                cancelRequestTimer()
                guard case let .proxy(parsedRequest) = initialRequest else {
                    if case let .pac(pacRequest) = initialRequest { sendPacFile(for: pacRequest) }
                    return
                }
                request = parsedRequest
                guard accessPolicy.evaluate(destination: parsedRequest.destination.address) == .allowed else {
                    rejectionHandler()
                    sendTerminalResponse(status: 403, reason: "Forbidden")
                    return
                }
                connectUpstream(for: parsedRequest)
            } catch HttpProxyParserError.headerTooLarge {
                rejectionHandler()
                sendTerminalResponse(status: 431, reason: "Request Header Fields Too Large")
            } catch HttpProxyParserError.unsupportedScheme {
                rejectionHandler()
                sendTerminalResponse(status: 501, reason: "Not Implemented")
            } catch HttpProxyParserError.methodNotAllowed {
                rejectionHandler()
                sendTerminalResponse(status: 405, reason: "Method Not Allowed")
            } catch {
                rejectionHandler()
                sendTerminalResponse(status: 400, reason: "Bad Request")
            }
        }
    }

    private func connectUpstream(for request: HttpProxyRequest) {
        state = .connecting
        do {
            let connection = try upstreamConnector.makeConnection(to: request.destination, egressMode: egressMode)
            upstream = connection
            connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
                guard let self, let connection, !didFinish else { return }
                switch connectionState {
                case .ready:
                    cancelUpstreamTimer()
                    upstreamReady(connection)
                case .waiting:
                    if state == .connecting && egressMode == .cellularOnly {
                        cancelUpstreamTimer()
                        sendTerminalResponse(status: 502, reason: "Bad Gateway")
                    }
                case .failed:
                    cancelUpstreamTimer()
                    if state == .connecting {
                        sendTerminalResponse(status: 502, reason: "Bad Gateway")
                    }
                case .cancelled:
                    if state == .connecting { finish() }
                default: break
                }
            }
            startUpstreamTimer()
            connection.start(queue: queue)
        } catch {
            sendTerminalResponse(status: 502, reason: "Bad Gateway")
        }
    }

    private func sendPacFile(for request: PacResourceRequest) {
        guard let proxyHost = pacProxyHost(),
              let response = PacFileGenerator.response(
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                sendsBody: request.sendsBody
              ) else {
            sendTerminalResponse(status: 503, reason: "Service Unavailable")
            return
        }
        isSendingTerminalResponse = true
        send(response) { [weak self] in self?.finish() }
    }

    private func pacProxyHost() -> String? {
        if case let .hostPort(host, _) = client.currentPath?.localEndpoint {
            switch host {
            case let .ipv4(address):
                let bytes = Array(address.rawValue)
                if bytes.count == 4, bytes[0] != 0 {
                    return bytes.map(String.init).joined(separator: ".")
                }
            case let .ipv6(address):
                let bytes = Array(address.rawValue)
                if bytes.count == 16, !bytes.allSatisfy({ $0 == 0 }) {
                    return Socks5Address.ipv6(bytes).displayValue
                }
            case let .name(name, _):
                if !name.isEmpty { return name }
            @unknown default:
                break
            }
        }
        return pacFallbackHost
    }

    private func upstreamReady(_ connection: NWConnection) {
        guard state == .connecting, let request else { return }
        if let decision = accessPolicy.evaluate(remoteEndpoint: connection.currentPath?.remoteEndpoint),
           decision != .allowed {
            rejectionHandler()
            sendTerminalResponse(status: 403, reason: "Forbidden")
            return
        }
        recordActivity()
        switch request.kind {
        case .connect:
            send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) { [weak self, weak connection] in
                guard let self, let connection else { return }
                startRelay(connection, initialUpload: request.initialUpstreamData)
            }
        case .forward:
            startRelay(connection, initialUpload: request.initialUpstreamData)
        }
    }

    private func startRelay(_ connection: NWConnection, initialUpload: Data) {
        guard !didFinish else { return }
        state = .relaying
        let newRelay = RelayPipe(
            client: client,
            upstream: connection,
            activityHandler: { [weak self] in self?.recordActivity() },
            uploadHandler: uploadHandler,
            downloadHandler: downloadHandler
        ) { [weak self] result in
            if case let .failure(error) = result {
                AppLogger.http.error("HTTP relay failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.finish()
        }
        relay = newRelay
        newRelay.start(initialUpload: initialUpload, uploadIsComplete: clientInputComplete)
    }

    private func sendResponse(status: Int, reason: String, then completion: @escaping @Sendable () -> Void) {
        send(Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), then: completion)
    }

    private func sendTerminalResponse(status: Int, reason: String) {
        guard !isSendingTerminalResponse, !didFinish else { return }
        isSendingTerminalResponse = true
        cancelRequestTimer()
        cancelUpstreamTimer()
        sendResponse(status: status, reason: reason) { [weak self] in self?.finish() }
    }

    private func send(_ data: Data, then completion: @escaping @Sendable () -> Void) {
        client.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil { recordActivity(); completion() } else { finish() }
        })
    }

    private func startRequestTimer() {
        guard requestTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + requestTimeout, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, state == .readingRequest else { return }
            sendTerminalResponse(status: 408, reason: "Request Timeout")
        }
        requestTimer = timer
        timer.resume()
    }

    private func cancelRequestTimer() {
        requestTimer?.setEventHandler {}
        requestTimer?.cancel()
        requestTimer = nil
    }

    private func startUpstreamTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.upstreamConnectionTimeout, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, state == .connecting else { return }
            sendTerminalResponse(status: 504, reason: "Gateway Timeout")
        }
        upstreamTimer = timer
        timer.resume()
    }

    private func cancelUpstreamTimer() {
        upstreamTimer?.setEventHandler {}
        upstreamTimer?.cancel()
        upstreamTimer = nil
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.idleTimerFired() }
        idleTimer = timer
        recordActivity()
        timer.resume()
    }

    private func recordActivity() {
        let now = Date()
        lastActivity = now
        let refreshInterval = min(5, max(0.25, idleTimeout / 4))
        if let lastIdleTimerScheduleDate,
           now.timeIntervalSince(lastIdleTimerScheduleDate) < refreshInterval { return }
        lastIdleTimerScheduleDate = now
        idleTimer?.schedule(deadline: .now() + idleTimeout, leeway: .seconds(1))
    }

    private func idleTimerFired() {
        guard !didFinish else { return }
        let remaining = idleTimeout - Date().timeIntervalSince(lastActivity)
        if remaining > 0 {
            lastIdleTimerScheduleDate = Date()
            idleTimer?.schedule(deadline: .now() + remaining, leeway: .seconds(1))
        } else {
            finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        state = .closed
        idleTimer?.setEventHandler {}
        idleTimer?.cancel()
        idleTimer = nil
        cancelRequestTimer()
        cancelUpstreamTimer()
        relay?.cancel()
        relay = nil
        upstream?.cancel()
        upstream = nil
        client.cancel()
        completion()
    }
}
