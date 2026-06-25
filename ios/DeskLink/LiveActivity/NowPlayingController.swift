import Foundation
import MediaPlayer
import ActivityKit
import UIKit

/// Bridges DeskLink's now-playing state to:
///   1. `MPNowPlayingInfoCenter` — makes iOS render it in the **Dynamic Island**
///      and on the Lock Screen automatically (album art, title, scrubber).
///   2. `MPRemoteCommandCenter` — the island/lock-screen play/pause/next/prev
///      buttons are forwarded back to the PC.
///   3. An ActivityKit **Live Activity** — custom Dynamic Island presentation
///      with album art (updated locally, no push needed → works on free sideload).
@MainActor
final class NowPlayingController {
    /// Sends a transport action string to the server ("play"/"pause"/"next"/"prev"/"toggle").
    var sendTransport: ((String) -> Void)?

    private var activity: Activity<DeskLinkActivityAttributes>?
    private var lastArtworkHash: Int = 0

    func activate() {
        configureRemoteCommands()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func deactivate() {
        endLiveActivity()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    // MARK: System Now Playing (Dynamic Island)

    func update(_ np: NowPlaying, serverName: String, canNext: Bool, canPrev: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: np.title,
            MPMediaItemPropertyArtist: np.artist,
            MPMediaItemPropertyAlbumTitle: np.album,
            MPNowPlayingInfoPropertyPlaybackRate: np.playing ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: Double(np.durationMs) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(np.positionMs) / 1000.0,
        ]
        if let data = np.artwork, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = np.playing ? .playing : .paused

        updateRemoteEnablement(canNext: canNext, canPrev: canPrev)
        updateLiveActivity(np, serverName: serverName)
    }

    // MARK: Remote command center

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.sendTransport?("play"); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.sendTransport?("pause"); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.sendTransport?("toggle"); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.sendTransport?("next"); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.sendTransport?("prev"); return .success }
    }

    private func updateRemoteEnablement(canNext: Bool, canPrev: Bool) {
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = canNext
        c.previousTrackCommand.isEnabled = canPrev
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
    }

    // MARK: Live Activity (Dynamic Island)

    private func updateLiveActivity(_ np: NowPlaying, serverName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = DeskLinkActivityAttributes.ContentState(
            title: np.title, artist: np.artist, playing: np.playing,
            sourceApp: np.app, artwork: np.artwork)

        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            let attributes = DeskLinkActivityAttributes(serverName: serverName)
            activity = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)   // local only — no APNs, works on free sideload
        }
    }

    private func endLiveActivity() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
