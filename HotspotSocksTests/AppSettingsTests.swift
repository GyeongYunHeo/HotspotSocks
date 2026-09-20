import XCTest
@testable import HotspotSocks

final class AppSettingsTests: XCTestCase {
    func testCurrentDefaults() {
        let settings = AppSettings()

        XCTAssertEqual(settings.socksPort, 9876)
        XCTAssertFalse(settings.httpProxyEnabled)
        XCTAssertEqual(settings.httpProxyPort, 9877)
        XCTAssertEqual(settings.egressMode, .systemDefault)
        XCTAssertEqual(settings.maximumClients, 128)
        XCTAssertEqual(settings.idleTimeout, 1_800)
        XCTAssertEqual(settings.backgroundDuration, 7_200)
        XCTAssertFalse(settings.allowPrivateNetworks)
    }

    func testSupportedBackgroundDurations() {
        XCTAssertEqual(
            BackgroundDurationOption.allCases.map(\.duration),
            [1_800, 3_600, 7_200, 14_400]
        )
        XCTAssertTrue(BackgroundDurationOption.supports(7_200))
        XCTAssertFalse(BackgroundDurationOption.supports(0))
    }

    func testServerRejectsZeroMaximumClients() {
        let server = ProxyServer { _ in }
        XCTAssertThrowsError(try server.start(port: 9876, maximumClients: 0, idleTimeout: 1_800)) { error in
            XCTAssertEqual(error as? ProxyServerError, .invalidMaximumClients)
        }
    }

    func testServerRejectsInvalidIdleTimeouts() {
        let server = ProxyServer { _ in }

        XCTAssertThrowsError(try server.start(port: 9876, maximumClients: 32, idleTimeout: 0)) { error in
            XCTAssertEqual(error as? ProxyServerError, .invalidIdleTimeout)
        }
        XCTAssertThrowsError(try server.start(port: 9876, maximumClients: 32, idleTimeout: .infinity)) { error in
            XCTAssertEqual(error as? ProxyServerError, .invalidIdleTimeout)
        }
    }

    func testConnectionLimiterSharesOneGlobalCeiling() {
        let limiter = ConnectionLimiter()

        XCTAssertTrue(limiter.acquire(maximum: 2))
        XCTAssertTrue(limiter.acquire(maximum: 2))
        XCTAssertFalse(limiter.acquire(maximum: 2))
        limiter.release()
        XCTAssertTrue(limiter.acquire(maximum: 2))
    }

    func testSettingsValidateSupportedValues() throws {
        try AppSettings().validate()
    }

    func testSettingsRejectInvalidValues() {
        var settings = AppSettings()
        settings.socksPort = 0
        XCTAssertThrowsError(try settings.validate()) {
            XCTAssertEqual($0 as? AppSettingsValidationError, .invalidPort)
        }

        settings = AppSettings()
        settings.backgroundDuration = 42
        XCTAssertThrowsError(try settings.validate()) {
            XCTAssertEqual($0 as? AppSettingsValidationError, .invalidBackgroundDuration)
        }

        settings = AppSettings(httpProxyEnabled: true, httpProxyPort: 9876)
        XCTAssertThrowsError(try settings.validate()) {
            XCTAssertEqual($0 as? AppSettingsValidationError, .duplicateProxyPorts)
        }
    }

    func testSettingsCodableRoundTrip() throws {
        let original = AppSettings(
            socksPort: 10_080,
            httpProxyEnabled: true,
            httpProxyPort: 10_081,
            egressMode: .cellularOnly,
            idleTimeout: 900,
            maximumClients: 12,
            allowPrivateNetworks: true,
            backgroundDuration: 3_600
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), original)
    }

    func testLegacySettingsDecodeWithHttpProxyDisabled() throws {
        let legacyJSON = """
        {
          "socksPort": 9876,
          "egressMode": "systemDefault",
          "idleTimeout": 1800,
          "maximumClients": 96,
          "allowPrivateNetworks": false,
          "backgroundDuration": 7200
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(decoded.httpProxyEnabled)
        XCTAssertEqual(decoded.httpProxyPort, 9877)
        XCTAssertEqual(decoded.maximumClients, 96)
    }

    @MainActor
    func testStoreMigratesLegacyDefaultMaximumClientsTo128() throws {
        let suiteName = "AppSettingsTests.migrate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var legacySettings = AppSettings()
        legacySettings.maximumClients = 32
        defaults.set(try JSONEncoder().encode(legacySettings), forKey: "app-settings-v1")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load().maximumClients, 128)

        var newlyCustomizedSettings = store.load()
        newlyCustomizedSettings.maximumClients = 32
        store.save(newlyCustomizedSettings)
        XCTAssertEqual(store.load().maximumClients, 32)
    }

    @MainActor
    func testStorePreservesCustomizedMaximumClientsDuringMigration() throws {
        let suiteName = "AppSettingsTests.preserve.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var customizedSettings = AppSettings()
        customizedSettings.maximumClients = 96
        defaults.set(try JSONEncoder().encode(customizedSettings), forKey: "app-settings-v1")

        XCTAssertEqual(
            AppSettingsStore(defaults: defaults).load().maximumClients,
            96
        )
    }
}
