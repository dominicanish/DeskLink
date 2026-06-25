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
            case .failed(let message):
                FailedView(message: message)
            default:
                DiscoveryView()
            }
        }
        .animation(.smooth, value: model.client.state)
        .onAppear { model.onAppear() }
    }
}

/// Shown when a connection attempt fails or times out.
struct FailedView: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Can't connect").font(.title2.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") { model.disconnect() }
                .buttonStyle(.glass)
                .padding(.top, 4)
        }
    }
}

#Preview { ContentView().environmentObject(AppModel()) }
