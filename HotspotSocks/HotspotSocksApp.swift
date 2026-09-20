import SwiftUI

@main
struct HotspotSocksApp: App {
    @StateObject private var viewModel = ProxyViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    viewModel.scenePhaseChanged(newPhase)
                }
        }
    }
}
