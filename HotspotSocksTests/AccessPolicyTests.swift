import Network
import XCTest
@testable import HotspotSocks

final class AccessPolicyTests: XCTestCase {
    func testLoopbackIsAlwaysBlocked() {
        for policy in [AccessPolicy(allowPrivateNetworks: false), AccessPolicy(allowPrivateNetworks: true)] {
            XCTAssertEqual(policy.evaluate(destination: .ipv4([127, 0, 0, 1])), .blocked(.loopback))
            XCTAssertEqual(policy.evaluate(destination: .ipv6(Array(repeating: 0, count: 15) + [1])), .blocked(.loopback))
            XCTAssertEqual(policy.evaluate(destination: .domain("localhost")), .blocked(.loopback))
            XCTAssertEqual(policy.evaluate(destination: .domain("api.LOCALHOST.")), .blocked(.loopback))
        }
    }

    func testPrivateAndLinkLocalDestinationsFollowSetting() {
        let denied = AccessPolicy(allowPrivateNetworks: false)
        let allowed = AccessPolicy(allowPrivateNetworks: true)
        let addresses: [Socks5Address] = [
            .ipv4([10, 0, 0, 1]),
            .ipv4([172, 20, 10, 4]),
            .ipv4([192, 168, 1, 1]),
            .ipv4([169, 254, 1, 2]),
            .ipv6([0xFC] + Array(repeating: 0, count: 15)),
            .ipv6([0xFE, 0x80] + Array(repeating: 0, count: 14)),
        ]

        for address in addresses {
            guard case .blocked = denied.evaluate(destination: address) else {
                XCTFail("Expected private destination to be blocked: \(address)")
                continue
            }
            XCTAssertEqual(allowed.evaluate(destination: address), .allowed)
        }
    }

    func testPublicDestinationsAreAllowed() {
        let policy = AccessPolicy(allowPrivateNetworks: false)
        XCTAssertEqual(policy.evaluate(destination: .ipv4([8, 8, 8, 8])), .allowed)
        XCTAssertEqual(policy.evaluate(destination: .domain("example.com")), .allowed)
        XCTAssertEqual(
            policy.evaluate(destination: .ipv6([0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 12))),
            .allowed
        )
    }

    func testNumericDomainCannotBypassAddressPolicy() {
        let policy = AccessPolicy(allowPrivateNetworks: false)
        XCTAssertEqual(policy.evaluate(destination: .domain("127.0.0.1")), .blocked(.loopback))
        XCTAssertEqual(policy.evaluate(destination: .domain("192.168.1.10")), .blocked(.privateNetwork))
        XCTAssertEqual(policy.evaluate(destination: .domain("::1")), .blocked(.loopback))
        XCTAssertEqual(policy.evaluate(destination: .domain("printer.local")), .blocked(.linkLocal))
        XCTAssertEqual(policy.evaluate(destination: .domain("bad..example")), .blocked(.invalidAddress))
    }

    func testUnspecifiedAndMulticastAreBlocked() {
        let policy = AccessPolicy(allowPrivateNetworks: true)
        XCTAssertEqual(policy.evaluate(destination: .ipv4([0, 0, 0, 0])), .blocked(.unspecified))
        XCTAssertEqual(policy.evaluate(destination: .ipv4([224, 0, 0, 1])), .blocked(.multicast))
        XCTAssertEqual(policy.evaluate(destination: .ipv6(Array(repeating: 0, count: 16))), .blocked(.unspecified))
        XCTAssertEqual(policy.evaluate(destination: .ipv6([0xFF] + Array(repeating: 0, count: 15))), .blocked(.multicast))
    }

    func testOnlyLocalClientEndpointsArePermitted() {
        let policy = AccessPolicy(allowPrivateNetworks: false)
        XCTAssertTrue(policy.permitsClient(.hostPort(host: "172.20.10.2", port: 50000)))
        XCTAssertTrue(policy.permitsClient(.hostPort(host: "100.64.0.2", port: 50000)))
        XCTAssertTrue(policy.permitsClient(.hostPort(host: "::1", port: 50000)))
        XCTAssertFalse(policy.permitsClient(.hostPort(host: "8.8.8.8", port: 50000)))
    }
}
