import SwiftUI

@MainActor
final class ProxyViewModel: ObservableObject {
    @Published private(set) var state: ProxyState = .stopped
    @Published private(set) var httpProxyState: ProxyState = .stopped
    @Published var settings: AppSettings {
        didSet { settingsStore.save(settings) }
    }
    @Published private(set) var statistics = TrafficStatisticsSnapshot()
    @Published private(set) var networkPath = NetworkPathSnapshot()
    @Published private(set) var interfaceAddresses: [InterfaceAddress] = []
    @Published private(set) var background = ContinuedProcessingSnapshot()
    @Published private(set) var scenePhaseLabel = "비활성"
    @Published private(set) var thermalState = ThermalStateSnapshot(
        level: ThermalLevel(ProcessInfo.processInfo.thermalState),
        observedAt: Date()
    )

    private var pathObserver: NetworkPathObserver?
    private var thermalMonitor: ThermalStateMonitor?
    private var pendingStopSuccess: Bool?
    private var socksServerState: ProxyState = .stopped
    private var stopWasRequested = false
    private var socksStatistics = TrafficStatisticsSnapshot()
    private var httpStatistics = TrafficStatisticsSnapshot()
    private let settingsStore: AppSettingsStore
    private let connectionLimiter = ConnectionLimiter()

    private lazy var backgroundController = ContinuedProcessingController(
        updateHandler: { [weak self] snapshot in
            self?.background = snapshot
        },
        stopHandler: { [weak self] reason in
            self?.stopForBackgroundReason(reason)
        }
    )

    private lazy var server = ProxyServer(
        stateHandler: { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.handleServerState(newState)
            }
        },
        statisticsHandler: { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.socksStatistics = snapshot
                self?.publishCombinedStatistics()
            }
        },
        connectionLimiter: connectionLimiter
    )

    private lazy var httpServer = HttpProxyServer(
        stateHandler: { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.handleHttpServerState(newState)
            }
        },
        statisticsHandler: { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.httpStatistics = snapshot
                self?.publishCombinedStatistics()
            }
        },
        connectionLimiter: connectionLimiter
    )

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        self.settingsStore = settingsStore
        settings = settingsStore.load()
        let observer = NetworkPathObserver { [weak self] snapshot in
            let addresses = InterfaceAddressResolver.activeAddresses()
            Task { @MainActor [weak self] in
                self?.networkPath = snapshot
                self?.interfaceAddresses = addresses
            }
        }
        pathObserver = observer
        observer.start()
        thermalMonitor = ThermalStateMonitor { [weak self] snapshot in
            self?.thermalState = snapshot
        }
    }

    deinit {
        pathObserver?.cancel()
    }

    var canStart: Bool {
        state == .stopped || state.isFailure
    }

    var canStop: Bool {
        state == .starting || state == .ready || state == .stopping
    }

    var userStatus: ProxyUserStatus {
        ProxyUserStatus(serviceState: state, activeConnections: statistics.activeConnections)
    }

    var preferredProxyHost: String? {
        preferredInterfaceAddress?.address
    }

    var pacConfigurationURL: String? {
        guard settings.httpProxyEnabled, let preferredProxyHost else { return nil }
        let host = preferredProxyHost.contains(":") ? "[\(preferredProxyHost)]" : preferredProxyHost
        return "http://\(host):\(settings.httpProxyPort)/wpad.dat"
    }

    var connectionSettingsText: String? {
        guard let preferredProxyHost else { return nil }
        var text = """
        SOCKS5 프록시
        호스트: \(preferredProxyHost)
        포트: \(settings.socksPort)
        인증: 없음
        """
        if settings.httpProxyEnabled {
            text += """


            HTTP 프록시 (선택 사항)
            호스트: \(preferredProxyHost)
            포트: \(settings.httpProxyPort)
            """
            if let pacConfigurationURL {
                text += """

                자동 설정 파일: \(pacConfigurationURL)
                """
            }
        }
        return text
    }

    var technicalErrorMessage: String? {
        guard case let .failed(message) = state else { return nil }
        return message
    }

    var diagnosticText: String {
        let addresses = interfaceAddresses.isEmpty
            ? "없음"
            : interfaceAddresses.map { "\($0.interfaceName) \($0.family.rawValue) \(endpointLabel(for: $0))" }.joined(separator: "\n")
        let routes = networkPath.activeInterfaces.isEmpty
            ? "없음"
            : networkPath.activeInterfaces.joined(separator: ", ")
        return """
        HotspotSocks 진단 정보
        프록시 상태: \(state.label)
        HTTP 프록시: \(settings.httpProxyEnabled ? httpProxyState.label : "사용 안 함")
        연결 방식: \(settings.egressMode.label)
        로컬 네트워크 접근: \(settings.allowPrivateNetworks ? "켜짐" : "꺼짐")
        수신 포트: \(settings.socksPort)
        HTTP 수신 포트: \(settings.httpProxyEnabled ? String(settings.httpProxyPort) : "사용 안 함")
        PAC 자동 설정 URL: \(pacConfigurationURL ?? "사용 안 함")
        시스템 네트워크: \(networkPath.statusLabel)
        현재 경로: \(routes)
        활성 연결: \(statistics.activeConnections)
        누적 연결: \(statistics.totalConnections)
        거부된 연결: \(statistics.rejectedConnections)
        다운로드 바이트: \(statistics.bytesDownloaded)
        업로드 바이트: \(statistics.bytesUploaded)
        발열 상태: \(thermalState.level.label)
        주소:
        \(addresses)
        최근 오류: \(technicalErrorMessage ?? "없음")
        """
    }

    private var preferredInterfaceAddress: InterfaceAddress? {
        interfaceAddresses.first { $0.address == "172.20.10.1" }
            ?? interfaceAddresses.first {
                $0.family == .ipv4 && $0.interfaceName.hasPrefix("bridge")
            }
    }

    func start() {
        guard canStart else { return }

        do {
            try settings.validate()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        state = .starting
        socksServerState = .starting
        stopWasRequested = false
        pendingStopSuccess = nil

        do {
            try backgroundController.begin(duration: settings.backgroundDuration)
        } catch {
            AppLogger.background.error("Background experiment unavailable; foreground proxy will continue: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try server.start(
                port: settings.socksPort,
                maximumClients: settings.maximumClients,
                idleTimeout: settings.idleTimeout,
                egressMode: settings.egressMode,
                allowPrivateNetworks: settings.allowPrivateNetworks
            )
            if settings.httpProxyEnabled {
                try httpServer.start(
                    port: settings.httpProxyPort,
                    maximumClients: settings.maximumClients,
                    idleTimeout: settings.idleTimeout,
                    egressMode: settings.egressMode,
                    allowPrivateNetworks: settings.allowPrivateNetworks,
                    pacFallbackHost: preferredProxyHost
                )
            } else {
                httpProxyState = .stopped
                httpStatistics = TrafficStatisticsSnapshot()
                publishCombinedStatistics()
            }
        } catch {
            server.stop()
            httpServer.stop()
            if background.state.isActive {
                backgroundController.finish(success: false, message: error.localizedDescription)
            }
            state = .failed(error.localizedDescription)
        }
    }

    func endpointLabel(for interfaceAddress: InterfaceAddress) -> String {
        switch interfaceAddress.family {
        case .ipv4: "\(interfaceAddress.address):\(settings.socksPort)"
        case .ipv6: "[\(interfaceAddress.address)]:\(settings.socksPort)"
        }
    }

    func httpEndpointLabel(for interfaceAddress: InterfaceAddress) -> String {
        switch interfaceAddress.family {
        case .ipv4: "\(interfaceAddress.address):\(settings.httpProxyPort)"
        case .ipv6: "[\(interfaceAddress.address)]:\(settings.httpProxyPort)"
        }
    }

    func stop() {
        guard canStop else { return }
        state = .stopping
        socksServerState = .stopping
        stopWasRequested = true
        if settings.httpProxyEnabled { httpProxyState = .stopping }
        pendingStopSuccess = true
        backgroundController.markStopping()
        server.stop()
        httpServer.stop()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: scenePhaseLabel = "활성"
        case .inactive: scenePhaseLabel = "비활성"
        case .background: scenePhaseLabel = "백그라운드"
        @unknown default: scenePhaseLabel = "알 수 없음"
        }
        AppLogger.background.info("Scene phase: \(self.scenePhaseLabel, privacy: .public); background task: \(self.background.state.label, privacy: .public); elapsed: \(self.background.elapsedTime, privacy: .public) seconds")
    }

    private func stopForBackgroundReason(_ reason: ContinuedProcessingStopReason) {
        guard canStop else { return }
        pendingStopSuccess = reason == .requestedDurationReached
        state = .stopping
        socksServerState = .stopping
        stopWasRequested = true
        if settings.httpProxyEnabled { httpProxyState = .stopping }
        server.stop()
        httpServer.stop()
    }

    private func handleServerState(_ newState: ProxyState) {
        socksServerState = newState
        switch newState {
        case .starting, .ready, .stopping:
            state = newState
        case .stopped:
            if state.isFailure { return }
            if settings.httpProxyEnabled && !httpProxyIsSettled {
                state = .stopping
                if !stopWasRequested {
                    stopWasRequested = true
                    httpServer.stop()
                }
            } else {
                finishStopLifecycle()
            }
        case let .failed(message):
            state = .failed(message)
            httpServer.stop()
            if background.state.isActive {
                backgroundController.finish(success: false, message: message)
            }
        }
    }

    private func handleHttpServerState(_ newState: ProxyState) {
        httpProxyState = newState
        if socksServerState == .stopped, httpProxyIsSettled, !state.isFailure {
            finishStopLifecycle()
        }
    }

    private var httpProxyIsSettled: Bool {
        httpProxyState == .stopped || httpProxyState.isFailure
    }

    private func finishStopLifecycle() {
        state = .stopped
        if background.state.isActive || background.state == .expired {
            let success = pendingStopSuccess ?? false
            backgroundController.finish(
                success: success,
                message: success ? nil : "백그라운드 작업이 만료되었거나 프록시가 예기치 않게 종료되었습니다."
            )
        }
        pendingStopSuccess = nil
        stopWasRequested = false
    }

    private func publishCombinedStatistics() {
        statistics = TrafficStatisticsSnapshot(
            activeConnections: socksStatistics.activeConnections + httpStatistics.activeConnections,
            totalConnections: socksStatistics.totalConnections + httpStatistics.totalConnections,
            bytesUploaded: socksStatistics.bytesUploaded &+ httpStatistics.bytesUploaded,
            bytesDownloaded: socksStatistics.bytesDownloaded &+ httpStatistics.bytesDownloaded,
            serverStartDate: [socksStatistics.serverStartDate, httpStatistics.serverStartDate]
                .compactMap { $0 }.min(),
            rejectedConnections: socksStatistics.rejectedConnections + httpStatistics.rejectedConnections
        )
    }
}
