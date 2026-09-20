import Foundation

enum AppSettingsValidationError: LocalizedError, Equatable {
    case invalidPort
    case duplicateProxyPorts
    case invalidMaximumClients
    case invalidIdleTimeout
    case invalidBackgroundDuration

    var errorDescription: String? {
        switch self {
        case .invalidPort: "수신 포트는 1에서 65535 사이여야 합니다."
        case .duplicateProxyPorts: "SOCKS5와 HTTP 프록시는 서로 다른 포트를 사용해야 합니다."
        case .invalidMaximumClients: "최대 연결 수는 1 이상이어야 합니다."
        case .invalidIdleTimeout: "유휴 연결 종료 시간은 유효한 양수여야 합니다."
        case .invalidBackgroundDuration: "지원되는 백그라운드 실행 시간을 선택해 주세요."
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var socksPort: UInt16 = 9876
    var httpProxyEnabled = false
    var httpProxyPort: UInt16 = 9877
    var egressMode: EgressMode = .systemDefault
    var idleTimeout: TimeInterval = 1_800
    var maximumClients: Int = 128
    var allowPrivateNetworks = false
    var backgroundDuration: TimeInterval = 7_200

    init(
        socksPort: UInt16 = 9876,
        httpProxyEnabled: Bool = false,
        httpProxyPort: UInt16 = 9877,
        egressMode: EgressMode = .systemDefault,
        idleTimeout: TimeInterval = 1_800,
        maximumClients: Int = 128,
        allowPrivateNetworks: Bool = false,
        backgroundDuration: TimeInterval = 7_200
    ) {
        self.socksPort = socksPort
        self.httpProxyEnabled = httpProxyEnabled
        self.httpProxyPort = httpProxyPort
        self.egressMode = egressMode
        self.idleTimeout = idleTimeout
        self.maximumClients = maximumClients
        self.allowPrivateNetworks = allowPrivateNetworks
        self.backgroundDuration = backgroundDuration
    }

    private enum CodingKeys: String, CodingKey {
        case socksPort, httpProxyEnabled, httpProxyPort, egressMode, idleTimeout
        case maximumClients, allowPrivateNetworks, backgroundDuration
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        socksPort = try values.decodeIfPresent(UInt16.self, forKey: .socksPort) ?? 9876
        httpProxyEnabled = try values.decodeIfPresent(Bool.self, forKey: .httpProxyEnabled) ?? false
        httpProxyPort = try values.decodeIfPresent(UInt16.self, forKey: .httpProxyPort) ?? 9877
        egressMode = try values.decodeIfPresent(EgressMode.self, forKey: .egressMode) ?? .systemDefault
        idleTimeout = try values.decodeIfPresent(TimeInterval.self, forKey: .idleTimeout) ?? 1_800
        maximumClients = try values.decodeIfPresent(Int.self, forKey: .maximumClients) ?? 128
        allowPrivateNetworks = try values.decodeIfPresent(Bool.self, forKey: .allowPrivateNetworks) ?? false
        backgroundDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .backgroundDuration) ?? 7_200
    }

    func validate() throws {
        guard socksPort > 0 else { throw AppSettingsValidationError.invalidPort }
        guard !httpProxyEnabled || httpProxyPort > 0 else { throw AppSettingsValidationError.invalidPort }
        guard !httpProxyEnabled || socksPort != httpProxyPort else {
            throw AppSettingsValidationError.duplicateProxyPorts
        }
        guard maximumClients > 0 else { throw AppSettingsValidationError.invalidMaximumClients }
        guard idleTimeout > 0, idleTimeout.isFinite else {
            throw AppSettingsValidationError.invalidIdleTimeout
        }
        guard BackgroundDurationOption.supports(backgroundDuration) else {
            throw AppSettingsValidationError.invalidBackgroundDuration
        }
    }
}

@MainActor
struct AppSettingsStore {
    private static let storageKey = "app-settings-v1"
    private static let maximumClientsMigrationKey = "maximum-clients-128-migration-v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.storageKey),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data),
              (try? settings.validate()) != nil else {
            defaults.set(true, forKey: Self.maximumClientsMigrationKey)
            return AppSettings()
        }

        if !defaults.bool(forKey: Self.maximumClientsMigrationKey) {
            if settings.maximumClients == 32 {
                settings.maximumClients = 128
                save(settings)
            }
            defaults.set(true, forKey: Self.maximumClientsMigrationKey)
        }

        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
