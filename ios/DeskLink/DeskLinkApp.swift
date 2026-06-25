import SwiftUI

@main
struct DeskLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)   // graphite, Apple-flavored
                .tint(.white)
        }
    }
}
