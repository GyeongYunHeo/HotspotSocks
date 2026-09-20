import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var didCopyDiagnostics = false

    var body: some View {
        Form {
            Section("프록시 수신 설정") {
                TextField("수신 포트", value: $viewModel.settings.socksPort, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .disabled(!viewModel.canStart)

                Picker("최대 연결 수", selection: $viewModel.settings.maximumClients) {
                    if !maximumClientOptions.contains(viewModel.settings.maximumClients) {
                        Text("\(viewModel.settings.maximumClients) (현재 값)")
                            .tag(viewModel.settings.maximumClients)
                    }
                    ForEach(maximumClientOptions, id: \.self) { value in
                        Text(value == 128 ? "128 (권장)" : String(value))
                            .tag(value)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!viewModel.canStart)

                Text("다중 연결을 많이 사용하는 속도 측정 앱에는 128을 권장합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("유휴 연결 종료", selection: $viewModel.settings.idleTimeout) {
                    Text("5분").tag(TimeInterval(300))
                    Text("15분").tag(TimeInterval(900))
                    Text("30분").tag(TimeInterval(1_800))
                    Text("1시간").tag(TimeInterval(3_600))
                }
                .disabled(!viewModel.canStart)
            }

            Section("HTTP 프록시 (선택 사항)") {
                Toggle("HTTP 프록시 사용", isOn: $viewModel.settings.httpProxyEnabled)
                    .disabled(!viewModel.canStart)

                if viewModel.settings.httpProxyEnabled {
                    TextField("HTTP 수신 포트", value: $viewModel.settings.httpProxyPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .disabled(!viewModel.canStart)

                    LabeledContent("현재 상태", value: viewModel.httpProxyState.label)
                }

                Text("일반 HTTP 전달과 HTTPS의 CONNECT 터널을 제공합니다. 같은 포트에서 wpad.dat 자동 설정 파일도 제공합니다. 기본 포트는 9877이며, SOCKS5가 기본 연결 방식입니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let pacURL = viewModel.pacConfigurationURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PAC 자동 설정 URL")
                            .font(.subheadline.weight(.semibold))
                        Text(pacURL)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("이 URL은 클라이언트에 직접 입력해야 하며 완전 자동 WPAD 탐색을 의미하지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("라우팅 및 보안") {
                Picker("연결 방식", selection: $viewModel.settings.egressMode) {
                    ForEach(EgressMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!viewModel.canStart)

                Toggle("로컬 네트워크 접근", isOn: $viewModel.settings.allowPrivateNetworks)
                    .disabled(!viewModel.canStart)

                Text("꺼져 있으면 사설 및 링크 로컬 목적지가 차단됩니다. 루프백, 미지정 주소, 멀티캐스트 주소는 이 설정과 관계없이 항상 차단됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !viewModel.canStart {
                    Label("실행 중인 연결에는 시작할 때 선택한 설정이 유지됩니다.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("연결 주소") {
                if viewModel.interfaceAddresses.isEmpty {
                    Text("활성화된 비루프백 주소가 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.interfaceAddresses) { interfaceAddress in
                        LabeledContent(
                            "\(interfaceAddress.interfaceName) · \(interfaceAddress.family.rawValue)",
                            value: viewModel.endpointLabel(for: interfaceAddress)
                        )
                    }
                }
            }

            Section("네트워크 경로") {
                LabeledContent("시스템 네트워크", value: viewModel.networkPath.statusLabel)
                LabeledContent("셀룰러", value: availabilityLabel(viewModel.networkPath.isCellularAvailable))
                LabeledContent("Wi‑Fi", value: availabilityLabel(viewModel.networkPath.isWiFiAvailable))
                LabeledContent(
                    "현재 경로",
                    value: viewModel.networkPath.activeInterfaces.isEmpty
                        ? "없음"
                        : viewModel.networkPath.activeInterfaces.joined(separator: ", ")
                )
            }

            Section("연결 및 트래픽") {
                LabeledContent("활성 연결", value: String(viewModel.statistics.activeConnections))
                LabeledContent("누적 연결", value: String(viewModel.statistics.totalConnections))
                LabeledContent("거부된 연결", value: String(viewModel.statistics.rejectedConnections))
                LabeledContent("다운로드", value: byteCountLabel(viewModel.statistics.bytesDownloaded))
                LabeledContent("업로드", value: byteCountLabel(viewModel.statistics.bytesUploaded))

                if let startDate = viewModel.statistics.serverStartDate {
                    LabeledContent("시작 시각") { Text(startDate, style: .time) }
                }
            }

            Section("백그라운드 실행 실험") {
                Picker("요청 시간", selection: $viewModel.settings.backgroundDuration) {
                    ForEach(BackgroundDurationOption.allCases) { option in
                        Text(option.label).tag(option.duration)
                    }
                }
                .disabled(!viewModel.canStart)

                LabeledContent("앱 상태", value: viewModel.scenePhaseLabel)
                LabeledContent("작업 상태", value: viewModel.background.state.label)

                if viewModel.background.state.isActive || viewModel.background.state == .completed {
                    ProgressView(value: viewModel.background.progress)
                    LabeledContent("경과 시간", value: durationLabel(viewModel.background.elapsedTime))
                    LabeledContent("남은 시간", value: durationLabel(viewModel.background.remainingTime))
                }

                Text("iOS의 실험적 연속 처리 기능입니다. 선택한 시간은 유한하며 운영체제가 작업을 더 일찍 종료할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("기기 상태") {
                LabeledContent("발열 상태", value: viewModel.thermalState.level.label)
            }

            Section("진단") {
                LabeledContent("프록시 내부 상태", value: viewModel.state.label)
                LabeledContent(
                    "HTTP 프록시 내부 상태",
                    value: viewModel.settings.httpProxyEnabled ? viewModel.httpProxyState.label : "사용 안 함"
                )

                if let error = viewModel.technicalErrorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("최근 오류")
                            .font(.subheadline.weight(.semibold))
                        Text(error)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("최근 오류", value: "없음")
                }

                Button {
                    UIPasteboard.general.string = viewModel.diagnosticText
                    didCopyDiagnostics = true
                } label: {
                    Label(didCopyDiagnostics ? "진단 정보 복사됨" : "진단 정보 복사", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .navigationTitle("고급 설정 및 진단")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func availabilityLabel(_ available: Bool) -> String {
        available ? "사용 가능" : "사용 불가"
    }

    private var maximumClientOptions: [Int] {
        [32, 64, 96, 128, 192, 256]
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }

    private func byteCountLabel(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .file)
    }
}
