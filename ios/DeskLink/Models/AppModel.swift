import Foundation
import Combine
import AVFoundation

/// Top-level coordinator: owns discovery, the WebSocket client, the audio engine
/// and the Dynamic Island bridge, and exposes simple state to the SwiftUI views.
@MainActor
final class AppModel: ObservableObject {
    let discovery = Discovery()
    let client = DeskLinkClient()

    private let audio = AudioEngine()
    private let nowPlaying = NowPlayingController()
    private var cancellables = Set<AnyCancellable>()
    private var pingTimer: Timer?

    // UI state
    @Published var micEnabled = false
    @Published var outputMuted = false
    @Published var serverName = "DeskLink"
    @Published var micPermissionDenied = false

    init() {
        // SwiftUI does not observe *nested* ObservableObjects: views read
        // `model.client.state` / `model.discovery.servers`, but only subscribe to
        // AppModel's own `objectWillChange`. Forward the children's change
        // notifications so the UI re-renders when the connection state, now-playing,
        // transport caps or the discovered-server list change. (Without this the
        // player stays stuck on "Connecting…", metadata never refreshes, and found
        // servers only appear after some *other* AppModel change forces a redraw.)
        client.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        discovery.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Route incoming PC audio into the engine.
        client.onPlaybackPayload = { [weak self] payload in
            self?.audio.enqueuePlayback(payload)
        }
        // Forward Dynamic Island / lock-screen transport buttons to the PC.
        nowPlaying.sendTransport = { [weak self] action in
            self?.client.sendControl(DeskLinkProtocol.transport(action))
        }

        // Mirror now-playing + transport-state into the Dynamic Island.
        client.$nowPlaying
            .combineLatest(client.$canNext, client.$canPrev)
            .sink { [weak self] np, canNext, canPrev in
                guard let self else { return }
                self.nowPlaying.update(np, serverName: self.serverName,
                                       canNext: canNext, canPrev: canPrev)
            }
            .store(in: &cancellables)

        client.$state
            .sink { [weak self] state in self?.onStateChange(state) }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    func onAppear() { discovery.start() }

    func connect(to server: DiscoveredServer, pairingCode: String?) {
        serverName = server.name
        client.connect(to: server.endpoint, pairingCode: pairingCode)
    }

    /// Manual connection by IP/host when Bonjour discovery isn't available.
    func connectManually(host: String, port: UInt16, pairingCode: String?) {
        serverName = host
        client.connect(host: host, port: port, pairingCode: pairingCode)
    }

    func disconnect() {
        client.disconnect()
        teardownAudio()
    }

    private func onStateChange(_ state: ConnectionState) {
        switch state {
        case .connected: setupAudio()
        case .idle, .failed: teardownAudio()
        default: break
        }
    }

    // MARK: Audio

    private func setupAudio() {
        do {
            try audio.configureSession()
            try audio.start()
            nowPlaying.activate()
            startPing()
        } catch {
            client.state = .failed("audio: \(error.localizedDescription)")
        }
    }

    private func teardownAudio() {
        stopPing()
        audio.stop()
        nowPlaying.deactivate()
        micEnabled = false
    }

    // MARK: Controls

    func toggleMic() {
        guard client.negotiatedCaps.contains(Capability.mic) else { return }
        if micEnabled {
            audio.stopMic()
            client.sendControl(DeskLinkProtocol.mic(enabled: false))
            micEnabled = false
        } else {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard granted else { self.micPermissionDenied = true; return }
                    // The tap callback runs on an audio thread; hop to the main
                    // actor before touching the @MainActor WebSocket client.
                    let started = self.audio.startMic { [weak self] payload, ts in
                        Task { @MainActor in self?.client.sendMicFrame(payload, timestampMicros: ts) }
                    }
                    guard started else { return }   // mic failed to open; stay off
                    self.client.sendControl(DeskLinkProtocol.mic(enabled: true))
                    self.micEnabled = true
                }
            }
        }
    }

    /// Mute = stop playing PC audio on THIS device (distinct from pausing the PC).
    func toggleOutputMute() {
        outputMuted.toggle()
        audio.setOutputMuted(outputMuted)
        client.sendControl(DeskLinkProtocol.outputMute(outputMuted))
    }

    // Transport (also reachable from the Dynamic Island).
    func play() { client.sendControl(DeskLinkProtocol.transport("play")) }
    func pause() { client.sendControl(DeskLinkProtocol.transport("pause")) }
    func togglePlayPause() { client.sendControl(DeskLinkProtocol.transport("toggle")) }
    func next() { client.sendControl(DeskLinkProtocol.transport("next")) }
    func previous() { client.sendControl(DeskLinkProtocol.transport("prev")) }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.client.ping() }
        }
    }
    private func stopPing() { pingTimer?.invalidate(); pingTimer = nil }
}
