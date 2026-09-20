import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.HotspotSocks"

    static let server = Logger(subsystem: subsystem, category: "server")
    static let socks = Logger(subsystem: subsystem, category: "socks")
    static let http = Logger(subsystem: subsystem, category: "http")
    static let relay = Logger(subsystem: subsystem, category: "relay")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let background = Logger(subsystem: subsystem, category: "background")
    static let udp = Logger(subsystem: subsystem, category: "udp")
    static let security = Logger(subsystem: subsystem, category: "security")
    static let performance = Logger(subsystem: subsystem, category: "performance")
}
