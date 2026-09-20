import Foundation

struct Socks5Parser: Sendable {
    enum State: Equatable, Sendable { case greeting, request, complete }

    private static let maximumIncompleteHandshakeSize = 512
    private(set) var state: State = .greeting
    private var buffer = Data()
    private var messagesBeforeFailure: [Socks5Message] = []

    mutating func append(_ data: Data) throws -> [Socks5Message] {
        buffer.append(data)
        messagesBeforeFailure.removeAll(keepingCapacity: true)
        var messages: [Socks5Message] = []

        do {
            while true {
                switch state {
                case .greeting:
                    guard let message = try parseGreeting() else {
                        try validateIncompleteBufferSize()
                        return messages
                    }
                    messages.append(message)
                    state = .request
                case .request:
                    guard let message = try parseRequest() else {
                        try validateIncompleteBufferSize()
                        return messages
                    }
                    messages.append(message)
                    state = .complete
                case .complete:
                    return messages
                }
            }
        } catch {
            messagesBeforeFailure = messages
            throw error
        }
    }

    mutating func takeMessagesBeforeFailure() -> [Socks5Message] {
        let messages = messagesBeforeFailure
        messagesBeforeFailure.removeAll(keepingCapacity: false)
        return messages
    }

    mutating func takeRemainingData() -> Data {
        guard state == .complete else { return Data() }
        let remaining = buffer
        buffer.removeAll(keepingCapacity: false)
        return remaining
    }

    private mutating func parseGreeting() throws -> Socks5Message? {
        guard let version = byte(at: 0) else { return nil }
        guard version == Socks5Protocol.version else { throw Socks5Error.unsupportedVersion(version) }
        guard let countByte = byte(at: 1) else { return nil }
        let count = Int(countByte)
        guard count > 0 else { throw Socks5Error.malformedGreeting }
        let length = 2 + count
        guard buffer.count >= length else { return nil }
        let methods = Array(data(in: 2..<length))
        buffer.removeFirst(length)
        return .greeting(methods: methods)
    }

    private mutating func parseRequest() throws -> Socks5Message? {
        guard let version = byte(at: 0) else { return nil }
        guard version == Socks5Protocol.version else { throw Socks5Error.unsupportedVersion(version) }
        guard buffer.count >= 4 else { return nil }
        guard byte(at: 2) == Socks5Protocol.reserved else { throw Socks5Error.malformedRequest }

        let commandByte = byte(at: 1)!
        guard let command = Socks5Command(rawValue: commandByte), command != .bind else {
            throw Socks5Error.unsupportedCommand(commandByte)
        }
        let typeByte = byte(at: 3)!
        guard let type = Socks5AddressType(rawValue: typeByte) else {
            throw Socks5Error.unsupportedAddressType(typeByte)
        }

        let parsed: (address: Socks5Address, portOffset: Int)
        switch type {
        case .ipv4:
            guard buffer.count >= 10 else { return nil }
            parsed = (.ipv4(Array(data(in: 4..<8))), 8)
        case .domain:
            guard let lengthByte = byte(at: 4) else { return nil }
            let length = Int(lengthByte)
            guard length > 0 else { throw Socks5Error.invalidDomain }
            let portOffset = 5 + length
            guard buffer.count >= portOffset + 2 else { return nil }
            guard let domain = String(data: data(in: 5..<portOffset), encoding: .utf8), !domain.isEmpty else {
                throw Socks5Error.invalidDomain
            }
            parsed = (.domain(domain), portOffset)
        case .ipv6:
            guard buffer.count >= 22 else { return nil }
            parsed = (.ipv6(Array(data(in: 4..<20))), 20)
        }

        guard let portHigh = byte(at: parsed.portOffset),
              let portLow = byte(at: parsed.portOffset + 1) else {
            throw Socks5Error.malformedRequest
        }
        let port = (UInt16(portHigh) << 8) | UInt16(portLow)
        if command == .connect, port == 0 { throw Socks5Error.invalidPort }
        buffer.removeFirst(parsed.portOffset + 2)
        let request = Socks5ConnectRequest(address: parsed.address, port: port)
        switch command {
        case .connect: return .connectRequest(request)
        case .udpAssociate: return .udpAssociateRequest(request)
        case .bind: throw Socks5Error.unsupportedCommand(commandByte)
        }
    }

    private func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < buffer.count else { return nil }
        return buffer[buffer.startIndex + offset]
    }

    /// Converts protocol-relative offsets to this Data value's potentially non-zero indices.
    private func data(in offsets: Range<Int>) -> Data.SubSequence {
        let lowerBound = buffer.startIndex + offsets.lowerBound
        let upperBound = buffer.startIndex + offsets.upperBound
        return buffer[lowerBound..<upperBound]
    }

    private func validateIncompleteBufferSize() throws {
        if buffer.count > Self.maximumIncompleteHandshakeSize { throw Socks5Error.handshakeTooLarge }
    }
}
