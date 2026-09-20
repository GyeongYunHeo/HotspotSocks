import Foundation
import Network

struct NetworkPathSnapshot: Equatable, Sendable {
    var isNetworkAvailable = false
    var isCellularAvailable = false
    var isWiFiAvailable = false
    var activeInterfaces: [String] = []

    var statusLabel: String {
        isNetworkAvailable ? "사용 가능" : "사용 불가"
    }
}

/// Observes the active system path and the availability of cellular and Wi-Fi paths.
final class NetworkPathObserver: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (NetworkPathSnapshot) -> Void

    private let queue = DispatchQueue(label: "com.example.HotspotSocks.path-monitor")
    private let systemMonitor = NWPathMonitor()
    private let cellularMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var snapshot = NetworkPathSnapshot()
    private var started = false
    private let updateHandler: UpdateHandler

    init(updateHandler: @escaping UpdateHandler) {
        self.updateHandler = updateHandler
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !started else { return }
            started = true
            configureHandlers()
            systemMonitor.start(queue: queue)
            cellularMonitor.start(queue: queue)
            wifiMonitor.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, started else { return }
            started = false
            systemMonitor.cancel()
            cellularMonitor.cancel()
            wifiMonitor.cancel()
        }
    }

    private func configureHandlers() {
        systemMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            snapshot.isNetworkAvailable = path.status == .satisfied
            snapshot.activeInterfaces = Self.activeInterfaceNames(for: path)
            publish()
        }
        cellularMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            snapshot.isCellularAvailable = path.status == .satisfied
            publish()
        }
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            snapshot.isWiFiAvailable = path.status == .satisfied
            publish()
        }
    }

    private func publish() {
        AppLogger.network.debug("Path: network=\(self.snapshot.isNetworkAvailable, privacy: .public), cellular=\(self.snapshot.isCellularAvailable, privacy: .public), wifi=\(self.snapshot.isWiFiAvailable, privacy: .public)")
        updateHandler(snapshot)
    }

    private static func activeInterfaceNames(for path: NWPath) -> [String] {
        let types: [(NWInterface.InterfaceType, String)] = [
            (.cellular, "셀룰러"),
            (.wifi, "Wi-Fi"),
            (.wiredEthernet, "유선 이더넷"),
            (.loopback, "루프백"),
            (.other, "기타"),
        ]
        return types.compactMap { path.usesInterfaceType($0.0) ? $0.1 : nil }
    }
}
