import Foundation

enum ThermalLevel: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "매우 높음"
        case .unknown: "알 수 없음"
        }
    }
}

struct ThermalStateSnapshot: Equatable, Sendable {
    let level: ThermalLevel
    let observedAt: Date
}

/// Notification-driven thermal observation; it creates no polling timer.
@MainActor
final class ThermalStateMonitor {
    typealias Handler = @MainActor (ThermalStateSnapshot) -> Void

    private let handler: Handler
    private var observation: NotificationObservation?

    init(handler: @escaping Handler) {
        self.handler = handler
        publish()
        let observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publish()
            }
        }
        observation = NotificationObservation(observer)
    }

    private func publish() {
        let snapshot = ThermalStateSnapshot(
            level: ThermalLevel(ProcessInfo.processInfo.thermalState),
            observedAt: Date()
        )
        handler(snapshot)
        AppLogger.performance.info("Thermal state changed: \(snapshot.level.rawValue, privacy: .public)")
    }
}

private final class NotificationObservation: @unchecked Sendable {
    private let observer: NSObjectProtocol

    init(_ observer: NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }
}
