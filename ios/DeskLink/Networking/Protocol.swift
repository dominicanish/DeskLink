import Foundation

/// Swift mirror of `server/desklink/protocol.py`. Control messages are JSON,
/// audio is a binary frame: [streamId:1][timestampMicros:8 LE][payload].
enum DeskLinkProtocol {

    // MARK: Binary audio framing

    static func encodeAudioFrame(stream: StreamID, timestampMicros: UInt64, payload: Data) -> Data {
        var out = Data(capacity: 9 + payload.count)
        out.append(stream.rawValue)
        var ts = timestampMicros.littleEndian
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    struct AudioFrame { let stream: UInt8; let timestampMicros: UInt64; let payload: Data }

    static func decodeAudioFrame(_ data: Data) -> AudioFrame? {
        guard data.count >= 9 else { return nil }
        let stream = data[data.startIndex]
        var ts: UInt64 = 0
        for i in 0..<8 {
            ts |= UInt64(data[data.startIndex + 1 + i]) << (8 * i)
        }
        let payload = data.subdata(in: (data.startIndex + 9)..<data.endIndex)
        return AudioFrame(stream: stream, timestampMicros: ts, payload: payload)
    }

    // MARK: Control messages (decoding)

    /// Loosely-typed control message: we only need `type` + a few fields.
    struct Control {
        let raw: [String: Any]
        var type: String { raw["type"] as? String ?? "" }
        subscript(_ key: String) -> Any? { raw[key] }
    }

    static func decodeControl(_ text: String) -> Control? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Control(raw: obj)
    }

    static func encode(_ message: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: Outgoing control builders

    static func join(client: String, pairingCode: String?, capabilities: [String],
                     playbackCodec: String, micCodec: String) -> String {
        var msg: [String: Any] = [
            "type": "join",
            "client": client,
            "capabilities": capabilities,
            "audio": ["playback": ["codec": playbackCodec], "mic": ["codec": micCodec]],
        ]
        if let code = pairingCode { msg["pairing_code"] = code }
        return encode(msg)
    }

    static func transport(_ action: String, positionMs: Int? = nil) -> String {
        var msg: [String: Any] = ["type": "transport", "action": action]
        if let p = positionMs { msg["positionMs"] = p }
        return encode(msg)
    }

    static func mic(enabled: Bool) -> String { encode(["type": "mic", "enabled": enabled]) }
    static func outputMute(_ muted: Bool) -> String { encode(["type": "output_mute", "muted": muted]) }
    static func ping(_ t: Double) -> String { encode(["type": "ping", "t": t]) }
}
