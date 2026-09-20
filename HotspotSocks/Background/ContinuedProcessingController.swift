import BackgroundTasks
import Foundation

enum BackgroundDurationOption: Int, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400

    var id: Int { rawValue }
    var duration: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .thirtyMinutes: "30분"
        case .oneHour: "1시간"
        case .twoHours: "2시간"
        case .fourHours: "4시간"
        }
    }

    static func supports(_ duration: TimeInterval) -> Bool {
        allCases.contains { $0.duration == duration }
    }
}

enum ContinuedProcessingState: Equatable, Sendable {
    case idle
    case submitted
    case running
    case stopping
    case completed
    case expired
    case failed(String)

    var label: String {
        switch self {
        case .idle: "대기"
        case .submitted: "제출됨"
        case .running: "실행 중"
        case .stopping: "종료 중"
        case .completed: "완료"
        case .expired: "만료됨"
        case let .failed(message): "실패: \(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .submitted, .running, .stopping: true
        default: false
        }
    }
}

struct ContinuedProcessingSnapshot: Equatable, Sendable {
    var state: ContinuedProcessingState = .idle
    var requestedDuration: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var progress: Double = 0

    var remainingTime: TimeInterval {
        max(0, requestedDuration - elapsedTime)
    }
}

enum ContinuedProcessingStopReason: Sendable {
    case requestedDurationReached
    case expiredBySystem
}

enum ContinuedProcessingError: LocalizedError, Equatable {
    case invalidDuration
    case registrationFailed
    case alreadyActive

    var errorDescription: String? {
        switch self {
        case .invalidDuration: "지원되는 백그라운드 실행 시간을 선택해 주세요."
        case .registrationFailed: "연속 처리 작업을 등록하지 못했습니다."
        case .alreadyActive: "연속 처리 작업이 이미 실행 중입니다."
        }
    }
}

/// Experimental, finite-duration wrapper around BGContinuedProcessingTask.
/// ProxyCore remains independent from BackgroundTasks.
@MainActor
final class ContinuedProcessingController {
    static let taskIdentifier = "\(Bundle.main.bundleIdentifier ?? "com.example.HotspotSocks").proxy-session"

    typealias UpdateHandler = (ContinuedProcessingSnapshot) -> Void
    typealias StopHandler = (ContinuedProcessingStopReason) -> Void

    private let scheduler: BGTaskScheduler
    private let updateHandler: UpdateHandler
    private let stopHandler: StopHandler
    private var isRegistered = false
    private var requestedDuration: TimeInterval?
    private var startedAt: Date?
    private var activeTask: BGContinuedProcessingTask?
    private var progressTask: Task<Void, Never>?
    private var hasRequestedStop = false
    private(set) var snapshot = ContinuedProcessingSnapshot()

    init(
        scheduler: BGTaskScheduler = .shared,
        updateHandler: @escaping UpdateHandler,
        stopHandler: @escaping StopHandler
    ) {
        self.scheduler = scheduler
        self.updateHandler = updateHandler
        self.stopHandler = stopHandler
    }

    func begin(duration: TimeInterval) throws {
        guard BackgroundDurationOption.supports(duration) else {
            throw ContinuedProcessingError.invalidDuration
        }
        guard !snapshot.state.isActive else {
            throw ContinuedProcessingError.alreadyActive
        }

        try registerIfNeeded()
        requestedDuration = duration
        startedAt = nil
        hasRequestedStop = false
        snapshot = ContinuedProcessingSnapshot(
            state: .submitted,
            requestedDuration: duration,
            elapsedTime: 0,
            progress: 0
        )
        publish()

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "HotspotSocks 프록시",
            subtitle: "시작 대기 중"
        )
        request.strategy = .fail

        do {
            try scheduler.submit(request)
            AppLogger.background.info("Continued-processing request submitted for \(duration, privacy: .public) seconds")
        } catch {
            requestedDuration = nil
            snapshot.state = .failed(error.localizedDescription)
            publish()
            AppLogger.background.error("Continued-processing submission failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func markStopping() {
        guard snapshot.state.isActive else { return }
        snapshot.state = .stopping
        publish()
    }

    func finish(success: Bool, message: String? = nil) {
        progressTask?.cancel()
        progressTask = nil

        if let activeTask {
            if success {
                activeTask.progress.completedUnitCount = activeTask.progress.totalUnitCount
            }
            activeTask.setTaskCompleted(success: success)
        } else {
            scheduler.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        }

        self.activeTask = nil
        requestedDuration = nil
        startedAt = nil
        hasRequestedStop = false

        if success {
            snapshot.state = .completed
        } else if snapshot.state != .expired {
            snapshot.state = .failed(message ?? "프록시 세션이 완료되기 전에 종료되었습니다.")
        }
        publish()
        AppLogger.background.info("Continued-processing task completed; success=\(success, privacy: .public)")
    }

    private func registerIfNeeded() throws {
        guard !isRegistered else { return }
        let registered = scheduler.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                self?.handle(task)
            }
        }
        guard registered else { throw ContinuedProcessingError.registrationFailed }
        isRegistered = true
        AppLogger.background.info("Registered continued-processing task \(Self.taskIdentifier, privacy: .public)")
    }

    private func handle(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask,
              let requestedDuration else {
            task.setTaskCompleted(success: false)
            return
        }

        activeTask = task
        startedAt = Date()
        snapshot.state = .running
        snapshot.elapsedTime = 0
        snapshot.progress = 0

        task.progress.totalUnitCount = Int64(requestedDuration)
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.expire()
            }
        }
        publish()
        updateSystemPresentation(for: task)
        AppLogger.background.info("Continued-processing task started")

        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func tick(now: Date = Date()) {
        guard snapshot.state == .running,
              let activeTask,
              let startedAt,
              let requestedDuration else { return }

        let elapsed = min(requestedDuration, max(0, now.timeIntervalSince(startedAt)))
        snapshot.elapsedTime = elapsed
        snapshot.progress = min(1, elapsed / requestedDuration)
        activeTask.progress.completedUnitCount = Int64(elapsed)
        updateSystemPresentation(for: activeTask)
        publish()

        guard elapsed >= requestedDuration, !hasRequestedStop else { return }
        hasRequestedStop = true
        snapshot.state = .stopping
        publish()
        AppLogger.background.info("Requested background duration reached")
        stopHandler(.requestedDurationReached)
    }

    private func expire() {
        guard snapshot.state.isActive, !hasRequestedStop else { return }
        hasRequestedStop = true
        progressTask?.cancel()
        progressTask = nil
        snapshot.state = .expired
        publish()
        AppLogger.background.error("Continued-processing task expired or was cancelled by the system")
        stopHandler(.expiredBySystem)
    }

    private func updateSystemPresentation(for task: BGContinuedProcessingTask) {
        let remainingMinutes = Int(ceil(snapshot.remainingTime / 60))
        task.updateTitle(
            "HotspotSocks 프록시",
            subtitle: "\(remainingMinutes)분 남음"
        )
    }

    private func publish() {
        updateHandler(snapshot)
    }
}
