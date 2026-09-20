import Foundation

enum ProxyUserStatus: Equatable, Sendable {
    case off
    case starting
    case ready
    case active
    case stopping
    case error

    init(serviceState: ProxyState, activeConnections: Int) {
        switch serviceState {
        case .stopped: self = .off
        case .starting: self = .starting
        case .ready: self = activeConnections > 0 ? .active : .ready
        case .stopping: self = .stopping
        case .failed: self = .error
        }
    }

    var title: String {
        switch self {
        case .off: "꺼짐"
        case .starting: "시작하는 중…"
        case .ready: "연결 준비됨"
        case .active: "사용 중"
        case .stopping: "종료하는 중…"
        case .error: "오류"
        }
    }

    var explanation: String {
        switch self {
        case .off: "프록시가 꺼져 있습니다."
        case .starting: "다른 기기에서 연결할 수 있도록 준비하고 있습니다."
        case .ready: "아래 주소와 포트로 다른 기기를 연결할 수 있습니다."
        case .active: "연결된 기기의 트래픽을 전달하고 있습니다."
        case .stopping: "연결을 안전하게 정리하고 있습니다."
        case .error: "HotspotSocks를 시작하지 못했습니다. 네트워크를 확인한 뒤 다시 시도해 주세요."
        }
    }

    var systemImage: String {
        switch self {
        case .off: "power"
        case .starting, .stopping: "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: "checkmark.circle.fill"
        case .active: "arrow.up.arrow.down.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}
