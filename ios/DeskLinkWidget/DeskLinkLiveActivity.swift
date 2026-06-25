import SwiftUI
import WidgetKit
import ActivityKit

/// Dynamic Island + Lock Screen Live Activity for DeskLink playback.
/// Uses `DeskLinkActivityAttributes` (shared with the app target).
struct DeskLinkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeskLinkActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    artwork(context).frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 8))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(context.state.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("via \(context.attributes.serverName)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } compactLeading: {
                artwork(context).frame(width: 20, height: 20).clipShape(.rect(cornerRadius: 4))
            } compactTrailing: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                    .font(.caption2)
            } minimal: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
            }
            .widgetURL(URL(string: "desklink://player"))
            .keylineTint(.white)
        }
    }

    @ViewBuilder
    private func artwork(_ context: ActivityViewContext<DeskLinkActivityAttributes>) -> some View {
        if let data = context.state.artwork, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack { Color.gray.opacity(0.3); Image(systemName: "music.note").font(.caption) }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<DeskLinkActivityAttributes>
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = context.state.artwork, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack { Color.gray.opacity(0.3); Image(systemName: "music.note") }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title).font(.headline).lineLimit(1)
                Text(context.state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("via \(context.attributes.serverName)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                .font(.title3).foregroundStyle(.secondary)
        }
    }
}
