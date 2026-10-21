import CDRipKit
import SwiftUI

/// The looks that the design repeats: the disc's rainbow sheen for progress, and the
/// colors of results.
enum Theme {
    static let sheenColors: [Color] = [
        Color(red: 0.72, green: 0.52, blue: 0.98), Color(red: 0.45, green: 0.66, blue: 1.0),
        Color(red: 0.45, green: 0.90, blue: 0.85), Color(red: 0.60, green: 0.92, blue: 0.55),
        Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 1.0, green: 0.62, blue: 0.62),
    ]

    static var sheen: LinearGradient {
        LinearGradient(colors: sheenColors, startPoint: .leading, endPoint: .trailing)
    }

    static var sheenRing: AngularGradient {
        AngularGradient(colors: sheenColors + [sheenColors[0]], center: .center)
    }

    static let good = Color.green
    static let warning = Color.orange
    static let bad = Color.red

    /// The color for an AccurateRip result.
    static func color(for status: RipReport.AccurateRipStatus) -> Color {
        switch status {
        case .accurate, .otherPressings: good
        case .notInDatabase: .secondary
        case .notAccurate: bad
        }
    }

    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.callout, design: .monospaced)
}

/// A small rounded label, as the design's chips.
struct Chip: View {
    enum Tone { case neutral, good, warning, bad }

    var text: String
    var tone = Tone.neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.bold()) }
            Text(text)
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .neutral: .primary
        case .good: Theme.good
        case .warning: Theme.warning
        case .bad: Theme.bad
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.secondary.opacity(0.15)
        case .good: Theme.good.opacity(0.14)
        case .warning: Theme.warning.opacity(0.16)
        case .bad: Theme.bad.opacity(0.14)
        }
    }
}

/// A progress bar filled with the sheen while reading, and green once verified.
struct SheenProgressBar: View {
    var fraction: Double
    var verified = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(verified ? AnyShapeStyle(Theme.good) : AnyShapeStyle(Theme.sheen))
                    .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
                    .animation(.linear(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

/// The sectors of a track with trouble, by position: C2 flags, unreadable, suspect, unresolved.
struct TrackErrorStrip: View {
    var errors: RipRun.TrackErrors

    var body: some View {
        Canvas { context, size in
            guard errors.sectors > 0 else { return }
            let width = size.width / Double(errors.sectors)
            func mark(_ sectors: Set<Int>, _ color: Color) {
                for sector in sectors where sector >= 0 && sector < errors.sectors {
                    let rect = CGRect(x: Double(sector) * width, y: 0, width: max(width, 1), height: size.height)
                    context.fill(Path(rect), with: .color(color))
                }
            }
            mark(errors.suspect, Theme.warning.opacity(0.7))
            mark(errors.flagged, Theme.warning)
            mark(errors.unreadable, Theme.bad)
            mark(errors.unresolved, Theme.bad)
        }
        .frame(height: 4)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 2))
    }
}

/// A cover, or a disc placeholder.
struct CoverView: View {
    var data: Data?
    var size: CGFloat = 132

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    VStack(spacing: 6) {
                        Image(systemName: "opticaldisc").font(.system(size: size / 4)).foregroundStyle(.secondary)
                        Text("Cover art").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
