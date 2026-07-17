import SwiftUI
import LocalMCPTwoProducerExampleSupport

@main
struct LocalMCPTwoProducerExampleApp: App {
    var body: some Scene {
        WindowGroup {
            TwoProducerDemoRootView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 720)
    }
}

private struct TwoProducerDemoRootView: View {
    @StateObject private var model = TwoProducerDemoViewModel()

    var body: some View {
        TwoProducerDemoView(model: model)
    }
}
