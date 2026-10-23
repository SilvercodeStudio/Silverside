import SilversideKit
import SwiftUI

/// The track that plays, at the bottom of the window: play or pause, the name, a position
/// slider, the times, and stop. It shows only while something plays or has just ended.
struct PlayerBar: View {
    let player: Player
    /// The slider's value while it is dragged; the seek happens when the drag ends.
    @State private var dragged: Double?

    var body: some View {
        if let item = player.item {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        player.togglePause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 24)
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "Pause" : "Play")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(player.error ?? item.subtitle)
                            .font(.caption)
                            .foregroundStyle(player.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.bad))
                            .lineLimit(1)
                    }
                    .frame(width: 240, alignment: .leading)
                    Text(Format.duration(seconds: Int(dragged ?? player.position)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { dragged ?? player.position }, set: { dragged = $0 }),
                        in: 0...max(item.seconds, 1)
                    ) { editing in
                        if !editing, let dragged {
                            player.seek(to: dragged)
                            self.dragged = nil
                        }
                    }
                    Text(Format.duration(seconds: Int(item.seconds)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        player.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

/// A play button for one track, in a table row: play, or pause when it is the track playing.
/// The player comes as a value, not from the environment: a table's cells are hosted by
/// AppKit, and the environment did not reach a cell when the table was rebuilt for another drive.
struct PlayButton: View {
    let player: Player
    let source: Player.Source
    var isEnabled = true
    let play: () -> Void

    var body: some View {
        let isCurrent = player.isCurrent(source)
        Button {
            if isCurrent { player.togglePause() } else { play() }
        } label: {
            Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle")
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isCurrent && player.isPlaying ? "Pause" : "Play")
    }
}
