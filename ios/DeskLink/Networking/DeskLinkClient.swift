import Foundation
import Network
import Combine

enum ConnectionState: Equatable {
    case idle
    case connecting
    case pairing            // server requires a code we haven't supplied/confirmed
    case connected
    case failed(String)
}

/// WebSocket client built on `URLSessionWebSocketTask`.
///
/// We use URLSession's WebSocket (not NWConnection) because it reliably performs
/// the opening handshake. `ws://` to a LAN address is allowed by the
/// `NSAllowsLocalNetworking` ATS exception in Info.plist.
@MainActor
final class DeskLinkClient: ObservableObject {
    @Published var state: ConnectionState = .idle
    @Published var nowPlaying = NowPlaying()
    @Published var canNext = false
    @Published var canPrev = false
    @Published var canSeek = false
    @Published var negotiatedCaps: [String] = []
    @Published var lastPingMs: Double = 0

    /// Receives decoded-ready playback payloads (opus or pcm) from the server.
    var onPlaybackPayload: ((Data) -> Void)?
    private(set) var playbackCodec = "pcm"
    private(set) var micCodec = "pcm"

    private var task: URLSessionWebSocketTask?
    /// Snapshot of `task` readable off the main actor for the mic-capture thread.
    /// `URLSessionWebSocketTask.send` is thread-safe; the worst case of a stale
    /// reference is a harmless failed send. Avoids hopping every mic frame to the
    /// main actor (which starved the playback receive loop → silence while miced).
    nonisolated(unsafe) private var micSendTask: URLSessionWebSocketTask?
    private var resolver: NWConnection?
    private var pairingCode: String?
    private let clientName = UIDeviceName()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg)
    }()

    // MARK: Connecting

    /// Connect by typed IP/host + port (the reliable, Bonjour-independent path).
    func connect(host: String, port: UInt16, pairingCode: String?) {
        guard let url = URL(string: "ws://\(host):\(port)/") else {
            state = .failed("Invalid address."); return
        }
        open(url: url, pairingCode: pairingCode)
    }

    /// Connect to a Bonjour-discovered endpoint. Service endpoints are resolved
    /// to host:port first (URLSession needs a concrete URL).
    func connect(to endpoint: NWEndpoint, pairingCode: String?) {
        if case let .hostPort(host, port) = endpoint {
            connect(host: Self.hostString(host), port: port.rawValue, pairingCode: pairingCode)
            return
        }
        resolve(endpoint, pairingCode: pairingCode)
    }

    private func open(url: URL, pairingCode: String?) {
        disconnect()
        self.pairingCode = pairingCode
        state = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        micSendTask = t
        t.resume()                 // initiates the WebSocket handshake
        receive()

        // Helpful hint if the handshake never completes.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            if case .connecting = self.state {
                self.state = .failed("Couldn't reach the server. Check the IP/port, that you're on the same Wi-Fi, and that Local Network is on in Settings → DeskLink.")
            }
        }
    }

    private func resolve(_ endpoint: NWEndpoint, pairingCode: String?) {
        state = .connecting
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolver = conn
        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready:
                    let remote = conn.currentPath?.remoteEndpoint
                    conn.cancel(); self.resolver = nil
                    if case let .hostPort(h, p) = remote {
                        self.connect(host: Self.hostString(h), port: p.rawValue, pairingCode: pairingCode)
                    } else {
                        self.state = .failed("Couldn't resolve the server address.")
                    }
                case .failed(let e):
                    conn.cancel(); self.resolver = nil
                    self.state = .failed(e.localizedDescription)
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)

        // Don't hang on "Connecting…" if Bonjour resolution stalls.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            if self.resolver === conn, case .connecting = self.state {
                conn.cancel(); self.resolver = nil
                self.state = .failed("Couldn't resolve the server over Bonjour. Use \"Connect by IP\" with the address shown on the PC.")
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        micSendTask = nil
        resolver?.cancel(); resolver = nil
        state = .idle
        negotiatedCaps = []
    }

    // MARK: Sending

    func sendControl(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    /// Called from the audio-capture thread (not the main actor) for each mic frame.
    nonisolated func sendMicFrame(_ payload: Data, timestampMicros: UInt64) {
        guard let t = micSendTask else { return }
        let frame = DeskLinkProtocol.encodeAudioFrame(stream: .mic,
                                                      timestampMicros: timestampMicros,
                                                      payload: payload)
        t.send(.data(frame)) { _ in }
    }

    func ping() {
        sendControl(DeskLinkProtocol.ping(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: Receiving

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    if case .connecting = self.state {
                        self.state = .failed(error.localizedDescription)
                    } else {
                        self.state = .idle
                    }
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleText(Data(text.utf8))
                    case .data(let data): self.handleBinary(data)
                    @unknown default: break
                    }
                    self.receive()   // keep listening
                }
            }
        }
    }

    private func handleBinary(_ data: Data) {
        guard let frame = DeskLinkProtocol.decodeAudioFrame(data) else { return }
        if frame.stream == StreamID.playback.rawValue {
            onPlaybackPayload?(frame.payload)
        }
    }

    private func handleText(_ data: Data) {
        guard let ctrl = DeskLinkProtocol.decodeControl(String(decoding: data, as: UTF8.self))
        else { return }
        switch ctrl.type {
        case "hello": handleHello(ctrl)
        case "ready": handleReady(ctrl)
        case "nowplaying": handleNowPlaying(ctrl)
        case "transport_state":
            canNext = ctrl["canNext"] as? Bool ?? false
            canPrev = ctrl["canPrev"] as? Bool ?? false
            canSeek = ctrl["canSeek"] as? Bool ?? false
        case "pong":
            if let t = ctrl["t"] as? Double {
                lastPingMs = (Date().timeIntervalSince1970 * 1000) - t
            }
        case "bye":
            state = .failed((ctrl["reason"] as? String) ?? "closed")
        default:
            break
        }
    }

    private func handleHello(_ ctrl: DeskLinkProtocol.Control) {
        let pairingRequired = ctrl["pairing_required"] as? Bool ?? false
        if pairingRequired && (pairingCode?.isEmpty ?? true) {
            state = .pairing
            return
        }
        let audio = ctrl["audio"] as? [String: Any]
        let serverPlayback = (audio?["playback"] as? [String: Any])?["codec"] as? String ?? "pcm"
        let serverMic = (audio?["mic"] as? [String: Any])?["codec"] as? String ?? "pcm"
        playbackCodec = OpusCodec.available && serverPlayback == "opus" ? "opus" : "pcm"
        micCodec = OpusCodec.available && serverMic == "opus" ? "opus" : "pcm"

        sendControl(DeskLinkProtocol.join(
            client: clientName, pairingCode: pairingCode,
            capabilities: Capability.clientSet,
            playbackCodec: playbackCodec, micCodec: micCodec))
    }

    private func handleReady(_ ctrl: DeskLinkProtocol.Control) {
        negotiatedCaps = ctrl["capabilities"] as? [String] ?? []
        let audio = ctrl["audio"] as? [String: Any]
        playbackCodec = (audio?["playback"] as? [String: Any])?["codec"] as? String ?? playbackCodec
        micCodec = (audio?["mic"] as? [String: Any])?["codec"] as? String ?? micCodec
        state = .connected
    }

    private func handleNowPlaying(_ ctrl: DeskLinkProtocol.Control) {
        var np = nowPlaying
        np.title = ctrl["title"] as? String ?? ""
        np.artist = ctrl["artist"] as? String ?? ""
        np.album = ctrl["album"] as? String ?? ""
        np.app = ctrl["app"] as? String ?? ""
        np.durationMs = ctrl["durationMs"] as? Int ?? 0
        np.positionMs = ctrl["positionMs"] as? Int ?? 0
        np.playing = ctrl["playing"] as? Bool ?? false
        if let b64 = ctrl["artwork"] as? String, let data = Data(base64Encoded: b64) {
            np.artwork = data
        }
        nowPlaying = np
    }

    // MARK: Helpers

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let n, _): return n
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        @unknown default: return "\(host)"
        }
    }
}

#if canImport(UIKit)
import UIKit
func UIDeviceName() -> String { UIDevice.current.name }
#else
func UIDeviceName() -> String { "iPhone" }
#endif
