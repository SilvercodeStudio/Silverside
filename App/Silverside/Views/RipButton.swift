import SilversideKit
import SwiftUI

/// The Rip button over the track table's lower right: the rip icon (`SilversideRipIcon.icon`), which moves
/// during a rip. Before a rip it starts one. During the rip level bars hang from the top and
/// bounce behind the arm, the laser's spot pulses, and a line fills around the edge; a click
/// asks to stop. After it, a badge shows the verdict, and a click opens the rip's results.
struct RipButton: View {
    @Environment(AppModel.self) private var model
    var slot: DriveSlot
    var size: CGFloat = 120
    @State private var stopAsked = false

    /// Its distance from the track table's edges.
    static let inset: CGFloat = 16

    var body: some View {
        Button(action: click) {
            RipPicture(look: look, size: size)
        }
        .buttonStyle(RipButtonStyle(cornerRadius: size * RipPicture.cornerRatio))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(accessibilityText)
        .confirmationDialog("Stop the rip?", isPresented: $stopAsked) {
            Button("Stop", role: .destructive) { model.stopRip(slot) }
        } message: {
            Text("Silverside stops after the read under way. The tracks ripped so far stay.")
        }
    }

    private var look: RipPicture.Look {
        guard let rip = slot.rip else { return .ready }
        switch rip.phase {
        case .starting: return .ripping(fraction: 0)
        case .ripping: return .ripping(fraction: rip.fraction)
        case .checkingCTDB: return .ripping(fraction: 1)
        case .encoding: return .ripping(fraction: rip.encodeFraction)
        case .finished: return rip.report.map { .done(verified: $0.isVerified) } ?? .ready
        case .stopped, .failed: return .ready
        }
    }

    private var enabled: Bool {
        if let rip = slot.rip, rip.isRunning || rip.phase == .finished { return true }
        return slot.disc != nil && !slot.isBusy && !slot.selectedTracks.isEmpty
    }

    private var help: String {
        switch look {
        case .ready:
            guard let disc = slot.disc, slot.selectedTracks.count != disc.toc.audioTracks.count else {
                return "Rip the disc (⌘R)"
            }
            return "Rip the selected tracks (⌘R)"
        case .ripping: return (slot.rip?.statusText ?? "Ripping") + ". Click to stop."
        case .done: return (slot.rip?.statusText ?? "Done") + ". Click to open the results."
        }
    }

    private var accessibilityText: String {
        switch look {
        case .ready: "Rip"
        case .ripping: slot.rip?.statusText ?? "Ripping"
        case .done: slot.rip?.statusText ?? "Done"
        }
    }

    private func click() {
        switch look {
        case .ready: model.startRip(slot)
        case .ripping: stopAsked = true
        case .done: openResults()
        }
    }

    /// Selects the rip in the sidebar, or shows its folder when the app does not list it
    /// (a demo rip, or a folder outside the rips folder and the library).
    private func openResults() {
        guard let rip = slot.rip, let report = rip.report else { return }
        if let recent = model.recentRips.first(where: { $0.report.toc == report.toc && $0.report.date == report.date })
        {
            model.selection = .rip(recent.file)
        } else if let folder = rip.folder {
            model.revealInFinder(folder)
        }
    }
}

/// Grows a little under the pointer and shrinks when pressed; grey when disabled.
private struct RipButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : hovering && isEnabled ? 1.03 : 1)
            .brightness(hovering && isEnabled ? 0.04 : 0)
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The picture, with the progress line around its edge and the verdict's badge. The icon is
/// two pictures that Icon Composer rendered (`App/Icon/make_rip_art.swift`): `RipArt`, the
/// whole icon, and `RipArtFront`, its arm, laser, disc, and rim alone. The bars go between them.
struct RipPicture: View {
    enum Look: Equatable {
        case ready
        case ripping(fraction: Double)
        case done(verified: Bool)
    }

    /// The radius of the icon's corners, as a part of its side (measured on the renders).
    static let cornerRatio: CGFloat = 0.26

    var look: Look
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// When the bars began to rise.
    @State private var rippingSince: Date?

    private var isRipping: Bool {
        if case .ripping = look { return true }
        return false
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isRipping || reduceMotion)) { timeline in
            let moving = isRipping && !reduceMotion
            let time = moving ? timeline.date.timeIntervalSinceReferenceDate : nil
            // The bars rise over the first second.
            let rise = moving ? min(1, timeline.date.timeIntervalSince(rippingSince ?? timeline.date) / 1) : 1
            ZStack {
                Canvas { context, canvasSize in
                    RipArt(time: time, bars: isRipping ? rise : 0, dark: colorScheme == .dark).draw(
                        in: &context, size: canvasSize.width)
                }
                frameLine(time: time)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: size * 0.04, y: size * 0.025)
        .overlay(alignment: .bottomTrailing) { badge }
        .onAppear { if isRipping { rippingSince = .now } }
        .onChange(of: isRipping) { _, ripping in rippingSince = ripping ? .now : nil }
    }

    private var outline: FrameOutline { FrameOutline(cornerRadius: size * Self.cornerRatio) }

    /// The progress line during a rip, in the progress bar's colors, which turn slowly; a
    /// green or orange edge after it.
    @ViewBuilder private func frameLine(time: TimeInterval?) -> some View {
        let width = size * 0.03
        let shape = FrameOutline(cornerRadius: size * Self.cornerRatio - width / 2).inset(by: width / 2)
        switch look {
        case .ready: EmptyView()
        case .ripping(let fraction):
            let turn = time.map { ($0 * 40).truncatingRemainder(dividingBy: 360) } ?? 0
            shape
                .trim(from: 0, to: max(0.005, fraction))
                .stroke(
                    AngularGradient(
                        colors: Theme.sheenColors + [Theme.sheenColors[0]], center: .center,
                        angle: .degrees(turn)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )
                .shadow(color: .white.opacity(0.6), radius: width * 0.6)
                .animation(.linear(duration: 0.3), value: fraction)
        case .done(let verified):
            shape
                .stroke(verified ? Theme.good : Theme.warning, lineWidth: width)
                .shadow(color: (verified ? Theme.good : Theme.warning).opacity(0.8), radius: width)
        }
    }

    @ViewBuilder private var badge: some View {
        if case .done(let verified) = look {
            Image(systemName: verified ? "checkmark" : "exclamationmark")
                .font(.system(size: size * 0.13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size * 0.28, height: size * 0.28)
                .background(verified ? Theme.good : Theme.warning, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: max(1.5, size * 0.015)))
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                .offset(x: size * 0.06, y: size * 0.06)
        }
    }
}

/// A rounded rectangle whose path starts at the top middle and runs clockwise, so that a
/// trimmed copy fills like a clock.
nonisolated struct FrameOutline: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(cornerRadius, r.width / 2, r.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addArc(
            center: CGPoint(x: r.maxX - c, y: r.minY + c), radius: c, startAngle: .degrees(-90), endAngle: .zero,
            clockwise: false)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addArc(
            center: CGPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: .zero, endAngle: .degrees(90),
            clockwise: false)
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addArc(
            center: CGPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: .degrees(90),
            endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.addArc(
            center: CGPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: .degrees(180),
            endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> FrameOutline {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Draws the rip icon in a 1024-unit square, as `SilversideRipIcon.icon` lays it out: the
/// whole icon, the level bars, then the arm, laser, disc, and rim over them. `time` (nil when
/// still) bounces the bars and pulses the laser's spot; `bars` (0 to 1) is how far they have risen.
struct RipArt {
    var time: TimeInterval?
    var bars: Double
    /// The pale colors need more strength on the light background.
    var dark = false

    static let side: CGFloat = 1024
    /// The bottom of the orange head, from `head.svg`: the bars reach no lower, so they stay
    /// well above the disc.
    private static let headBottom = 380.0
    /// The laser's spot on the disc, from `spot.svg`.
    private static let spot = CGPoint(x: 512, y: 622)
    private static let barCount = 15

    func draw(in context: inout GraphicsContext, size: CGFloat) {
        let all = CGRect(x: 0, y: 0, width: size, height: size)
        context.draw(Image("RipArt"), in: all)
        context.scaleBy(x: size / Self.side, y: size / Self.side)
        if bars > 0 { levelBars(&context) }
        context.scaleBy(x: Self.side / size, y: Self.side / size)
        context.draw(Image("RipArtFront"), in: all)
        context.scaleBy(x: size / Self.side, y: size / Self.side)
        if let time { pulse(&context, time: time) }
    }

    /// Bars that hang from the top edge, at most as far as the bottom of the head, and shorter
    /// near the laser so that they frame it. While ripping they bounce, in the progress bar's colors, which
    /// drift along them.
    private func levelBars(_ context: inout GraphicsContext) {
        var layer = context
        layer.clip(
            to: FrameOutline(cornerRadius: Self.side * RipPicture.cornerRatio).path(
                in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side)))
        layer.opacity = dark ? 0.75 : 0.9
        let left = 40.0
        let width = (Self.side - 2 * left) / Double(Self.barCount)
        for index in 0..<Self.barCount {
            let x = left + Double(index) * width
            let middle = x + width / 2
            let level: Double
            if let time {
                let speed = 2.6 + Double(index % 7) * 0.45
                level = 0.2 + 0.8 * abs(sin(time * speed + Double(index) * 1.9))
            } else {
                level = 0.35 + 0.5 * abs(sin(Double(index) * 1.7 + 0.5))
            }
            let nearLaser = 1 - 0.4 * exp(-pow((middle - Self.spot.x) / 110, 2))
            let length = Self.headBottom * level * nearLaser * bars
            let color = time.map { Self.sheen(at: Double(index) / Double(Self.barCount) - $0 * 0.2) } ?? .white
            let bar = CGRect(x: x + width * 0.2, y: -40, width: width * 0.6, height: length + 40)
            layer.fill(Path(roundedRect: bar, cornerRadius: width * 0.3), with: .color(color))
        }
    }

    /// The laser's spot brightens and fades, about once a second.
    private func pulse(_ context: inout GraphicsContext, time: TimeInterval) {
        let strength = 0.5 + 0.5 * sin(time * 5)
        // spot.svg's gradient: a circle of radius 160, squashed to the disc's slant.
        var layer = context
        layer.translateBy(x: Self.spot.x, y: Self.spot.y)
        layer.scaleBy(x: 1, y: 0.4545)
        layer.fill(
            Path(ellipseIn: CGRect(x: -160, y: -160, width: 320, height: 320)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(red: 1, green: 0.95, blue: 0.93).opacity(0.9 * strength), location: 0),
                    .init(color: Color(red: 1, green: 0.48, blue: 0.43).opacity(0.6 * strength), location: 0.12),
                    .init(color: Color(red: 1, green: 0.23, blue: 0.19).opacity(0.25 * strength), location: 0.45),
                    .init(color: Color(red: 1, green: 0.23, blue: 0.19).opacity(0), location: 1),
                ]), center: .zero, startRadius: 0, endRadius: 160))
    }

    /// A color of `Theme.sheenColors`, taken round as a loop: 0 and 1 are the first color.
    private static func sheen(at position: Double) -> Color {
        let colors = Theme.sheenColors
        let place = (position - position.rounded(.down)) * Double(colors.count)
        let index = Int(place) % colors.count
        return colors[index].mix(with: colors[(index + 1) % colors.count], by: place - place.rounded(.down))
    }
}
