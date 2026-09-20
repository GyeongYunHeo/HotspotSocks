import Foundation
import Network

enum EgressMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemDefault
    case cellularOnly

    var id: Self { self }

    var label: String {
        switch self {
        case .systemDefault: "자동"
        case .cellularOnly: "셀룰러 전용"
        }
    }

    var explanation: String {
        switch self {
        case .systemDefault:
            "iOS가 선택한 네트워크 경로를 사용합니다."
        case .cellularOnly:
            "프록시 트래픽을 셀룰러 데이터로만 보냅니다. Wi‑Fi나 다른 경로로 자동 전환하지 않습니다."
        }
    }

    var requiredInterfaceType: NWInterface.InterfaceType? {
        switch self {
        case .systemDefault: nil
        case .cellularOnly: .cellular
        }
    }
}
