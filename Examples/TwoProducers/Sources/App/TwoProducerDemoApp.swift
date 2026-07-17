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
    // Constructed in an explicit initializer rather than a property-wrapper
    // default expression: Swift 6.0's IRGen crashes emitting the backing
    // initializer for a @StateObject default that expands cross-module
    // default arguments.
    @StateObject private var model: TwoProducerDemoViewModel

    init() {
        _model = StateObject(wrappedValue: TwoProducerDemoViewModel(demo: TwoProducerDemo()))
    }

    var body: some View {
        TwoProducerDemoView(model: model)
    }
}
