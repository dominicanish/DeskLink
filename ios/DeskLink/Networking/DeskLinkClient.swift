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

/// WebSocket client over Network.framework.
///
/// Latency: TCP_NODELAY is enabled and WebSocket permessage-deflate is left off,
/// so 20 ms audio frames are flushed to the wire immediately.
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
    /// Asks the audio engine which codec was negotiated for each stream.
    private(set) var playbackCodec = "pcm"
    private(set) var micCodec = "pcm"

    private var connection: NWConnection?
    private var pairingCode: String?
    private var clientName = UIDeviceName()

    func connect(to endpoint: NWEndpoint, pairingCode: String?) {
        disconnect()
        self.pairingCode = pairingCode
        state = .connecting

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                     // <- low latency
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in self?.handleNWState(st) }
        }
        conn.start(queue: .main)
        receiveLoop()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        state = .idle
        negotiatedCaps = []
    }

    private func handleNWState(_ st: NWConnection.State) {
        switch st {
        case .failed(let err): state = .failed(err.localizedDescription)
        case .cancelled: if state != .idle { state = .idle }
        default: break
        }
    }

    // MARK: Sending

    func sendControl(_ text: String) {
        send(text.data(using: .utf8) ?? Data(), opcode: .text)
    }

    func sendMicFrame(_ payload: Data, timestampMicros: UInt64) {
        let frame = DeskLinkProtocol.encodeAudioFrame(stream: .mic,
                                                      timestampMicros: timestampMicros,
                                                      payload: payload)
        send(frame, opcode: .binary)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        guard let conn = connection else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
        let ctx = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    // MARK: Receiving

    private func receiveLoop() {
        guard let conn = connection else { return }
        conn.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, let context,
                   let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata {
                    switch meta.opcode {
                    case .text: self.handleText(data)
                    case .binary: self.handleBinary(data)
                    case .close: self.state = .idle
                    default: break
                    }
                }
                if error == nil { self.receiveLoop() }
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
        guard let text = String(data: data, encoding: .utf8),
              let ctrl = DeskLinkProtocol.decodeControl(text) else { return }
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
        default: break
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
        // We can decode Opus if OpusKit is linked; otherwise request pcm.
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

    func ping() {
        sendControl(DeskLinkProtocol.ping(Date().timeIntervalSince1970 * 1000))
    }
}

#if canImport(UIKit)
import UIKit
func UIDeviceName() -> String { UIDevice.current.name }
#else
func UIDeviceName() -> String { "iPhone" }
#endif
