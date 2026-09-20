import XCTest
@testable import HotspotSocks

final class HttpProxyParserTests: XCTestCase {
    func testConnectDomainPreservesCoalescedTunnelBytes() throws {
        var parser = HttpProxyParser()
        let tunnelBytes = Data([0x16, 0x03, 0x01, 0x00])
        var input = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8)
        input.append(tunnelBytes)

        let request = try proxyRequest(from: parser.append(input))

        XCTAssertEqual(request.kind, .connect)
        XCTAssertEqual(request.destination, Socks5ConnectRequest(address: .domain("example.com"), port: 443))
        XCTAssertEqual(request.initialUpstreamData, tunnelBytes)
    }

    func testConnectSupportsIPv4AndBracketedIPv6() throws {
        var ipv4Parser = HttpProxyParser()
        let ipv4 = try proxyRequest(from: ipv4Parser.append(Data("CONNECT 1.1.1.1:443 HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertEqual(ipv4.destination, Socks5ConnectRequest(address: .ipv4([1, 1, 1, 1]), port: 443))

        var ipv6Parser = HttpProxyParser()
        let ipv6 = try proxyRequest(from: ipv6Parser.append(Data("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n\r\n".utf8)))
        guard case let .ipv6(bytes) = ipv6.destination.address else {
            return XCTFail("Expected IPv6 destination")
        }
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(ipv6.destination.port, 8443)
    }

    func testFragmentedForwardRequestIsRewrittenToOriginForm() throws {
        var parser = HttpProxyParser()
        XCTAssertNil(try parser.append(Data("GET http://example.com:8080/path?q=1 HTTP/1.1\r\nPro".utf8)))
        let request = try proxyRequest(from: parser.append(Data("xy-Connection: keep-alive\r\nProxy-Authorization: secret\r\nHost: wrong.test\r\nAccept: */*\r\n\r\n".utf8)))
        let rewritten = try XCTUnwrap(String(data: request.initialUpstreamData, encoding: .isoLatin1))

        XCTAssertEqual(request.kind, .forward)
        XCTAssertEqual(request.destination, Socks5ConnectRequest(address: .domain("example.com"), port: 8080))
        XCTAssertTrue(rewritten.hasPrefix("GET /path?q=1 HTTP/1.1\r\n"))
        XCTAssertTrue(rewritten.contains("Host: example.com:8080\r\n"))
        XCTAssertFalse(rewritten.lowercased().contains("proxy-connection"))
        XCTAssertFalse(rewritten.lowercased().contains("proxy-authorization"))
        XCTAssertFalse(rewritten.contains("wrong.test"))
        XCTAssertTrue(rewritten.contains("Connection: close\r\n"))
    }

    func testForwardRequestPreservesBodyAfterHeaders() throws {
        var parser = HttpProxyParser()
        let request = try proxyRequest(from: parser.append(Data("POST http://example.com/upload HTTP/1.1\r\nContent-Length: 4\r\n\r\nbody".utf8)))
        XCTAssertTrue(request.initialUpstreamData.suffix(4).elementsEqual(Data("body".utf8)))
    }

    func testRejectsHttpsAbsoluteFormAndMalformedConnect() {
        var httpsParser = HttpProxyParser()
        XCTAssertThrowsError(try httpsParser.append(Data("GET https://example.com/ HTTP/1.1\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HttpProxyParserError, .unsupportedScheme)
        }

        var connectParser = HttpProxyParser()
        XCTAssertThrowsError(try connectParser.append(Data("CONNECT example.com HTTP/1.1\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HttpProxyParserError, .malformedRequest)
        }
    }

    func testRejectsOversizedHeaders() {
        var parser = HttpProxyParser()
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: HttpProxyParser.maximumHeaderLength + 1))) {
            XCTAssertEqual($0 as? HttpProxyParserError, .headerTooLarge)
        }
    }

    func testRecognizesGetAndHeadWpadResource() throws {
        var getParser = HttpProxyParser()
        let getResult = try XCTUnwrap(getParser.append(Data("GET /wpad.dat?cache=1 HTTP/1.1\r\nHost: 172.20.10.1:9877\r\n\r\n".utf8)))
        XCTAssertEqual(getResult, .pac(PacResourceRequest(sendsBody: true)))

        var headParser = HttpProxyParser()
        let headResult = try XCTUnwrap(headParser.append(Data("HEAD /wpad.dat HTTP/1.1\r\nHost: 172.20.10.1:9877\r\n\r\n".utf8)))
        XCTAssertEqual(headResult, .pac(PacResourceRequest(sendsBody: false)))
    }

    func testPacScriptAdvertisesOnlyRequestedHttpProxy() throws {
        let data = try XCTUnwrap(PacFileGenerator.script(proxyHost: "172.20.10.1", proxyPort: 9877))
        let script = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(script.contains("function FindProxyForURL(url, host)"))
        XCTAssertTrue(script.contains("PROXY 172.20.10.1:9877"))
        XCTAssertFalse(script.contains("DIRECT"))
        XCTAssertFalse(script.contains("9876"))
    }

    func testPacScriptBracketsIPv6AndRejectsInjection() throws {
        let data = try XCTUnwrap(PacFileGenerator.script(proxyHost: "2001:db8::1", proxyPort: 9877))
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("PROXY [2001:db8::1]:9877"))
        XCTAssertNil(PacFileGenerator.script(proxyHost: "host\"; return \"DIRECT", proxyPort: 9877))
    }

    func testPacHttpResponseHasRequiredHeadersAndHeadOmitsBody() throws {
        let getResponse = try XCTUnwrap(PacFileGenerator.response(
            proxyHost: "172.20.10.1",
            proxyPort: 9877,
            sendsBody: true
        ))
        let getText = try XCTUnwrap(String(data: getResponse, encoding: .utf8))
        XCTAssertTrue(getText.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(getText.contains("Content-Type: application/x-ns-proxy-autoconfig\r\n"))
        XCTAssertTrue(getText.contains("Cache-Control: no-store, no-cache, must-revalidate\r\n"))
        XCTAssertTrue(getText.contains("FindProxyForURL"))

        let headResponse = try XCTUnwrap(PacFileGenerator.response(
            proxyHost: "172.20.10.1",
            proxyPort: 9877,
            sendsBody: false
        ))
        let headText = try XCTUnwrap(String(data: headResponse, encoding: .utf8))
        XCTAssertFalse(headText.contains("FindProxyForURL"))
        XCTAssertTrue(headText.contains("Content-Length: "))
    }

    private func proxyRequest(from result: HttpInitialRequest?) throws -> HttpProxyRequest {
        guard case let .proxy(request) = try XCTUnwrap(result) else {
            throw HttpProxyParserError.malformedRequest
        }
        return request
    }
}
