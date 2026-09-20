import Foundation
import Network

enum RelayError: Error, LocalizedError {
    case transferFailed(Error)

    var errorDescription: String? {
        switch self {
        case let .transferFailed(error): "TCP relay failed: \(error.localizedDescription)"
        }
    }
}

/// Reads the next chunk only after the preceding send finishes, in both directions.
final class RelayPipe: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void
    typealias ActivityHandler = @Sendable () -> Void

    private enum Direction: String {
        case upload
        case download
    }

    private enum DirectionState {
        case pumping
        case propagatingEOF
        case finished
    }

    private static let maximumReceiveLength = 64 * 1_024
    private let client: NWConnection
    private let upstream: NWConnection
    private let activityHandler: ActivityHandler
    private let uploadHandler: @Sendable (Int) -> Void
    private let downloadHandler: @Sendable (Int) -> Void
    private let completion: Completion
    private var uploadState: DirectionState = .pumping
    private var downloadState: DirectionState = .pumping
    private var finished = false

    init(
        client: NWConnection,
        upstream: NWConnection,
        activityHandler: @escaping ActivityHandler,
        uploadHandler: @escaping @Sendable (Int) -> Void = { _ in },
        downloadHandler: @escaping @Sendable (Int) -> Void = { _ in },
        completion: @escaping Completion
    ) {
        self.client = client
        self.upstream = upstream
        self.activityHandler = activityHandler
        self.uploadHandler = uploadHandler
        self.downloadHandler = downloadHandler
        self.completion = completion
    }

    func start(initialUpload: Data = Data(), uploadIsComplete: Bool = false) {
        pump(from: upstream, to: client, direction: .download)
        guard !initialUpload.isEmpty else {
            if uploadIsComplete {
                sendWriteClose(to: upstream, direction: .upload)
            } else {
                pump(from: client, to: upstream, direction: .upload)
            }
            return
        }
        activityHandler()
        uploadHandler(initialUpload.count)
        if uploadIsComplete { setState(.propagatingEOF, for: .upload) }
        upstream.send(
            content: initialUpload,
            contentContext: uploadIsComplete ? .finalMessage : .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { finish(.failure(RelayError.transferFailed(error))) }
                else if uploadIsComplete { directionFinished(.upload) }
                else { pump(from: client, to: upstream, direction: .upload) }
            }
        )
    }

    func cancel() {
        finished = true
    }

    private func pump(from source: NWConnection, to destination: NWConnection, direction: Direction) {
        guard !finished, state(for: direction) == .pumping else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReceiveLength) {
            [weak self] content, _, isComplete, error in
            guard let self, !finished, state(for: direction) == .pumping else { return }
            AppLogger.relay.debug("\(direction.rawValue, privacy: .public) receive: \(content?.count ?? 0, privacy: .public) bytes, complete=\(isComplete, privacy: .public)")
            if let content, !content.isEmpty {
                activityHandler()
                switch direction {
                case .upload: uploadHandler(content.count)
                case .download: downloadHandler(content.count)
                }
                if isComplete { setState(.propagatingEOF, for: direction) }
                destination.send(
                    content: content,
                    contentContext: isComplete ? .finalMessage : .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if let sendError { finish(.failure(RelayError.transferFailed(sendError))) }
                        else if isComplete { directionFinished(direction) }
                        else if let error { finish(.failure(RelayError.transferFailed(error))) }
                        else { pump(from: source, to: destination, direction: direction) }
                    }
                )
            } else if let error {
                finish(.failure(RelayError.transferFailed(error)))
            } else if isComplete {
                sendWriteClose(to: destination, direction: direction)
            } else {
                pump(from: source, to: destination, direction: direction)
            }
        }
    }

    private func sendWriteClose(to destination: NWConnection, direction: Direction) {
        guard state(for: direction) == .pumping else { return }
        setState(.propagatingEOF, for: direction)
        AppLogger.relay.info("\(direction.rawValue, privacy: .public) EOF received; propagating TCP write-close")
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    finish(.failure(RelayError.transferFailed(error)))
                    return
                }
                directionFinished(direction)
            }
        )
    }

    private func directionFinished(_ direction: Direction) {
        guard state(for: direction) != .finished else { return }
        setState(.finished, for: direction)
        AppLogger.relay.info("\(direction.rawValue, privacy: .public) direction finished")
        if uploadState == .finished && downloadState == .finished {
            AppLogger.relay.info("Both relay directions finished")
            finish(.success(()))
        }
    }

    private func state(for direction: Direction) -> DirectionState {
        switch direction {
        case .upload: uploadState
        case .download: downloadState
        }
    }

    private func setState(_ state: DirectionState, for direction: Direction) {
        switch direction {
        case .upload: uploadState = state
        case .download: downloadState = state
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }
}
