import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            // Subtle graphite backdrop (not bright), matching the logo.
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            switch model.client.state {
            case .connected:
                PlayerView()
            case .connecting:
                ProgressView("Connecting…").controlSize(.large)
            case .pairing:
                PairingView()
            default:
                DiscoveryView()
            }
        }
        .animation(.smooth, value: model.client.state)
        .onAppear { model.onAppear() }
    }
}

#Preview { ContentView().environmentObject(AppModel()) }
