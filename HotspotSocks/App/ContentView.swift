import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var didCopySettings = false
    @State private var didCopyPacURL = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard
                    primaryAction
                    connectionOptionsCard
                    connectionGuideCard
                    statisticsCard

                    NavigationLink {
                        SettingsView(viewModel: viewModel)
                    } label: {
                        Label("고급 설정 및 진단", systemImage: "gearshape.2")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("HotspotSocks")
        }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.userStatus.systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: viewModel.userStatus.isTransitioning)

            Text(viewModel.userStatus.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(viewModel.userStatus.explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("프록시 상태, \(viewModel.userStatus.title)")
        .accessibilityHint(viewModel.userStatus.explanation)
    }

    private var primaryAction: some View {
        Button {
            didCopySettings = false
            didCopyPacURL = false
            if viewModel.canStart {
                viewModel.start()
            } else {
                viewModel.stop()
            }
        } label: {
            Label(primaryActionTitle, systemImage: viewModel.canStart ? "play.fill" : "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.canStart ? .accentColor : .red)
        .disabled(viewModel.userStatus.isTransitioning)
        .accessibilityHint(viewModel.canStart ? "프록시를 시작합니다." : "프록시와 모든 연결을 종료합니다.")
    }

    private var connectionOptionsCard: some View {
        GroupBox("연결 방식") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("연결 방식", selection: $viewModel.settings.egressMode) {
                    ForEach(EgressMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.canStart)

                Text(viewModel.settings.egressMode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("로컬 네트워크 접근", isOn: $viewModel.settings.allowPrivateNetworks)
                    .disabled(!viewModel.canStart)

                Text("켜면 연결된 기기가 사설 네트워크의 컴퓨터, NAS 또는 개발 서버에 접속할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !viewModel.canStart {
                    Label("설정을 바꾸려면 먼저 프록시를 종료해 주세요.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.settings.egressMode == .cellularOnly,
                   !viewModel.networkPath.isCellularAvailable {
                    Label {
                        Text("셀룰러 연결을 사용할 수 없습니다. Wi‑Fi나 다른 경로로 자동 전환하지 않습니다.")
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("주의: 셀룰러 연결을 사용할 수 없습니다.")
                }
            }
            .padding(.top, 8)
        }
    }

    private var connectionGuideCard: some View {
        GroupBox("다른 기기 연결") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("프록시 종류", value: "SOCKS5")
                LabeledContent("호스트", value: viewModel.preferredProxyHost ?? "감지된 주소 없음")
                LabeledContent("포트", value: String(viewModel.settings.socksPort))
                LabeledContent("인증", value: "없음")

                if viewModel.settings.httpProxyEnabled {
                    Divider()
                    LabeledContent("선택형 HTTP 프록시", value: viewModel.httpProxyState.label)
                    LabeledContent("HTTP 포트", value: String(viewModel.settings.httpProxyPort))

                    if let pacURL = viewModel.pacConfigurationURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PAC 자동 설정 URL")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(pacURL)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)

                        Text("지원하는 기기의 프록시 자동 설정 URL에 직접 등록하세요. DHCP나 DNS를 이용한 자동 탐색 기능은 포함되지 않습니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            UIPasteboard.general.string = pacURL
                            didCopyPacURL = true
                        } label: {
                            Label(didCopyPacURL ? "PAC URL 복사됨" : "PAC URL 복사", systemImage: didCopyPacURL ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("PAC 자동 설정 URL만 클립보드에 복사합니다.")
                    }

                    if case let .failed(message) = viewModel.httpProxyState {
                        Label("HTTP 프록시를 시작하지 못했습니다: \(message)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if viewModel.preferredProxyHost == nil {
                    Text("활성화된 로컬 네트워크 주소를 찾지 못했습니다. 개인용 핫스팟 또는 네트워크 연결을 확인해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("기기에서 실제로 감지한 주소입니다. 모든 주소는 고급 설정 및 진단에서 확인할 수 있습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    guard let settings = viewModel.connectionSettingsText else { return }
                    UIPasteboard.general.string = settings
                    didCopySettings = true
                } label: {
                    Label(didCopySettings ? "설정 복사됨" : "연결 설정 복사", systemImage: didCopySettings ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.connectionSettingsText == nil)
                .accessibilityHint("활성화된 프록시의 호스트와 포트 정보를 클립보드에 복사합니다.")
            }
            .padding(.top, 8)
        }
    }

    private var statisticsCard: some View {
        GroupBox("사용 현황") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statistic("활성 연결", value: String(viewModel.statistics.activeConnections), image: "link")
                    statistic("다운로드", value: byteCountLabel(viewModel.statistics.bytesDownloaded), image: "arrow.down")
                    statistic("업로드", value: byteCountLabel(viewModel.statistics.bytesUploaded), image: "arrow.up")
                }

                VStack(spacing: 12) {
                    statistic("활성 연결", value: String(viewModel.statistics.activeConnections), image: "link")
                    statistic("다운로드", value: byteCountLabel(viewModel.statistics.bytesDownloaded), image: "arrow.down")
                    statistic("업로드", value: byteCountLabel(viewModel.statistics.bytesUploaded), image: "arrow.up")
                }
            }
            .padding(.top, 8)
        }
    }

    private func statistic(_ title: String, value: String, image: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: image)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var primaryActionTitle: String {
        switch viewModel.userStatus {
        case .starting: "시작하는 중…"
        case .stopping: "종료하는 중…"
        case .off, .error: "프록시 시작"
        case .ready, .active: "프록시 종료"
        }
    }

    private var statusColor: Color {
        switch viewModel.userStatus {
        case .ready, .active: .green
        case .starting, .stopping: .orange
        case .error: .red
        case .off: .secondary
        }
    }

    private func byteCountLabel(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .file)
    }
}
