import SilversideKit
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
    /// Sectors that reads never settled, but CTDB fixed.
    static let fixed = Color.blue

    /// The color for an AccurateRip result.
    static func color(for status: RipReport.AccurateRipStatus) -> Color {
        switch status {
        case .accurate, .otherPressings: good
        case .notInDatabase, .noChecksum: .secondary
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
    /// A small spinner in place of the image, for work under way.
    var isWorking = false
    /// A logo from the asset catalog before the text, such as "HDCD", drawn in the text's color.
    var logo: String?
    /// The tooltip, for a chip in a `ChipRow`.
    var help: String?
    /// A web page that a click opens.
    var link: URL?

    var body: some View {
        if let link {
            Link(destination: link) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            if isWorking {
                ProgressView().controlSize(.mini)
            } else if let logo {
                Image(logo).resizable().scaledToFit().frame(height: 13)
            } else if let systemImage {
                Image(systemName: systemImage).font(.caption2.bold())
            }
            Text(text)
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .help(help ?? "")
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

/// Views in rows, as words wrap: a view that does not fit on its row starts the next one, so a
/// row of chips grows taller in a narrow window, not wider.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each view at its own size, left to right, and centered on its row's height.
    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var rows = [[(index: Int, size: CGSize)]]()
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rows.isEmpty || (x > 0 && x + spacing + size.width > width) {
                // A view kept with the one before it takes that one to the new row.
                let previous =
                    subview[KeepsWithPrevious.self] && (rows.last?.count ?? 0) > 1
                    ? rows[rows.count - 1].popLast() : nil
                rows.append(previous.map { [$0] } ?? [])
                x = previous?.size.width ?? 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rows[rows.count - 1].append((index, size))
        }
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        for row in rows {
            let height = row.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for (index, size) in row {
                frames[index] = CGRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)
                x += size.width + spacing
            }
            y += height + rowSpacing
        }
        return frames
    }
}

private nonisolated struct KeepsWithPrevious: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// In a `FlowLayout`, the view never starts a row by itself: it goes to the next row with
    /// the view before it, as an info button with its chip.
    func keepsWithPrevious() -> some View { layoutValue(key: KeepsWithPrevious.self, value: true) }
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
