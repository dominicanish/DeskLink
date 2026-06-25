import SwiftUI

/// Shown when a server requires a pairing code but we connected without one.
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 40, weight: .light))
            Text("Pairing required").font(.title2.weight(.semibold))
            Text("Disconnect and reconnect entering the 6-digit code shown on your PC.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button("Back") { model.disconnect() }
                .buttonStyle(.glass)
        }
    }
}

/// Bottom sheet to enter the pairing code before connecting.
struct PairingSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: DiscoveredServer
    @State private var code = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect to \(server.name)").font(.headline)
            Text("Enter the 6-digit code shown on your PC")
                .font(.subheadline).foregroundStyle(.secondary)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onChange(of: code) { _, new in code = String(new.prefix(6)) }

            Button {
                model.connect(to: server, pairingCode: code)
                dismiss()
            } label: {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(code.count < 6)
        }
        .padding(24)
    }
}
