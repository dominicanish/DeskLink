import SwiftUI

/// Lists DeskLink servers found on the LAN. Liquid Glass cards.
struct DiscoveryView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingServer: DiscoveredServer?

    var body: some View {
        VStack(spacing: 24) {
            header

            if model.discovery.servers.isEmpty {
                searching
            } else {
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        ForEach(model.discovery.servers) { server in
                            Button { select(server) } label: {
                                ServerRow(server: server)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
        }
        .padding(.top, 60)
        .sheet(item: $pendingServer) { server in
            PairingSheet(server: server)
                .presentationDetents([.medium])
                .presentationBackground(.thinMaterial)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
            Text("DeskLink").font(.largeTitle.weight(.semibold))
            Text("Find your PC on this Wi-Fi network")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var searching: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Searching…").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func select(_ server: DiscoveredServer) {
        pendingServer = server
    }
}

private struct ServerRow: View {
    let server: DiscoveredServer
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.headline)
                Text("Tap to connect").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
