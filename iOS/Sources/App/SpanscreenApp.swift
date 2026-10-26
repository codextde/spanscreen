import SwiftUI

@main
struct SpanscreenApp: App {
    @StateObject private var model = ReceiverModel.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
        }
    }
}
