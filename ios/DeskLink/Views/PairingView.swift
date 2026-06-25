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

/// Bottom sheet to connect by typed IP/host when Bonjour discovery fails.
struct ManualConnectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("Connect by IP").font(.headline)
            Text("Type the address shown by the PC server, e.g. 192.168.1.50:8765")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("192.168.1.50:8765", text: $address)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 16))

            TextField("Pairing code (optional)", text: $code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onChange(of: code) { _, new in code = String(new.prefix(6)) }

            Button {
                let (host, port) = Self.parse(address)
                model.connectManually(host: host, port: port,
                                      pairingCode: code.isEmpty ? nil : code)
                dismiss()
            } label: {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(address.isEmpty)
        }
        .padding(24)
    }

    /// Split "host:port" → (host, port); default port 8765.
    static func parse(_ raw: String) -> (String, UInt16) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            let port = UInt16(trimmed[trimmed.index(after: colon)...]) ?? 8765
            return (host, port)
        }
        return (trimmed, 8765)
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
