import Foundation
import ActivityKit

/// Capability identifiers — must match `server/desklink/protocol.py`.
enum Capability {
    static let playback = "audio.playback"
    static let mic = "audio.mic"
    static let nowPlaying = "meta.nowplaying"
    static let transport = "transport"
    static let dynamicIsland = "dynamic_island"

    /// What this client is able and willing to use.
    static let clientSet = [playback, mic, nowPlaying, transport, dynamicIsland]
}

/// Binary audio stream ids — must match the server.
enum StreamID: UInt8 {
    case playback = 1   // PC -> phone
    case mic = 2        // phone -> PC
}

let kProtocolVersion = 1

/// Now-playing snapshot shown in the UI, the system Now Playing center,
/// and the Dynamic Island Live Activity.
struct NowPlaying: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var app: String = ""
    var durationMs: Int = 0
    var positionMs: Int = 0
    var playing: Bool = false
    /// Decoded album art (set only when the track changes).
    var artwork: Data? = nil
}

/// ActivityKit attributes that drive the Dynamic Island / Lock Screen Live Activity.
/// Shared between the app target and the widget extension target.
struct DeskLinkActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var playing: Bool
        var sourceApp: String
        /// Album art as PNG/JPEG bytes (kept small; islands are tiny).
        var artwork: Data?
    }

    var serverName: String
}
