import SwiftUI

/// The connected player: album art, metadata, transport, mic + output controls.
struct PlayerView: View {
    @EnvironmentObject var model: AppModel

    private var np: NowPlaying { model.client.nowPlaying }

    var body: some View {
        VStack(spacing: 28) {
            topBar
            artwork
            metadata
            transportControls
            Spacer()
            bottomControls
        }
        .padding(.horizontal, 24)
        .padding(.top, 50)
        .padding(.bottom, 30)
    }

    // MARK: Top bar (server + latency + disconnect)

    private var topBar: some View {
        HStack {
            Label(model.serverName, systemImage: "desktopcomputer")
                .font(.subheadline.weight(.medium))
            Spacer()
            if model.client.lastPingMs > 0 {
                Text("\(Int(model.client.lastPingMs)) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { model.disconnect() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    // MARK: Artwork

    private var artwork: some View {
        Group {
            if let data = np.artwork, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    Rectangle().fill(.thinMaterial)
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 24))
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .frame(maxWidth: 320)
    }

    // MARK: Metadata

    private var metadata: some View {
        VStack(spacing: 6) {
            Text(np.title.isEmpty ? "Nothing playing" : np.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text(np.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if !np.app.isEmpty {
                Text(friendlyApp(np.app))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Transport

    private var transportControls: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                transportButton("backward.fill", enabled: model.client.canPrev) { model.previous() }
                Button { model.togglePlayPause() } label: {
                    Image(systemName: np.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(.glassProminent)
                .clipShape(.circle)
                transportButton("forward.fill", enabled: model.client.canNext) { model.next() }
            }
        }
    }

    private func transportButton(_ symbol: String, enabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 60, height: 60)
        }
        .buttonStyle(.glass)
        .clipShape(.circle)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Bottom (mic + output mute)

    private var bottomControls: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                ToggleChip(
                    title: model.micEnabled ? "Mic On" : "Mic Off",
                    symbol: model.micEnabled ? "mic.fill" : "mic.slash.fill",
                    active: model.micEnabled,
                    available: model.client.negotiatedCaps.contains(Capability.mic)
                ) { model.toggleMic() }

                ToggleChip(
                    title: model.outputMuted ? "Muted" : "Listening",
                    symbol: model.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    active: model.outputMuted,
                    available: true
                ) { model.toggleOutputMute() }
            }
        }
    }

    private func friendlyApp(_ id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("spotify") { return "Spotify" }
        if lower.contains("apple") || lower.contains("music") { return "Apple Music" }
        if lower.contains("chrome") { return "Chrome" }
        if lower.contains("msedge") || lower.contains("edge") { return "Edge" }
        return id
    }
}

private struct ToggleChip: View {
    let title: String
    let symbol: String
    let active: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            // Prominent (tinted) glass when active, regular glass otherwise.
            .glassEffect(active ? .regular.tint(.white.opacity(0.22)).interactive()
                                : .regular.interactive(),
                         in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
    }
}
