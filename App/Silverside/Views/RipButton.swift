import SilversideKit
import SwiftUI

/// The Rip button under the track table: the design's "rip" picture (`App/Icon/Silverside.rip_btn.svg`),
/// drawn here so that it can move. Before a rip it starts one. During the rip the disc turns,
/// the bars on the beam bounce, and a line fills around the frame; a click asks to stop.
/// After it, a badge shows the verdict, and a click opens the rip's results.
struct RipButton: View {
    @Environment(AppModel.self) private var model
    var slot: DriveSlot
    var size: CGFloat = 120
    @State private var stopAsked = false

    var body: some View {
        Button(action: click) {
            RipPicture(look: look, size: size)
        }
        .buttonStyle(RipButtonStyle(cornerRadius: size * RipArt.frameRadius / RipArt.side))
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

/// The picture, with the progress line on its frame and the verdict's badge.
struct RipPicture: View {
    enum Look: Equatable {
        case ready
        case ripping(fraction: Double)
        case done(verified: Bool)
    }

    var look: Look
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRipping: Bool {
        if case .ripping = look { return true }
        return false
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isRipping || reduceMotion)) { timeline in
            let time = isRipping && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : nil
            Canvas { context, canvasSize in
                RipArt(time: time).draw(in: &context, size: canvasSize.width)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.03)
        .overlay { frameLine }
        .overlay(alignment: .bottomTrailing) { badge }
    }

    private var unit: CGFloat { size / RipArt.side }

    /// The progress line during a rip, and a green or orange frame after it.
    @ViewBuilder private var frameLine: some View {
        let shape = FrameOutline(cornerRadius: (RipArt.frameRadius - 4.5) * unit).inset(by: 4.5 * unit)
        switch look {
        case .ready: EmptyView()
        case .ripping(let fraction):
            shape
                .trim(from: 0, to: max(0.005, fraction))
                .stroke(RipArt.blue, style: StrokeStyle(lineWidth: 6 * unit, lineCap: .round))
                .shadow(color: RipArt.blue.opacity(0.9), radius: 4 * unit)
                .animation(.linear(duration: 0.3), value: fraction)
        case .done(let verified):
            shape
                .stroke(verified ? Theme.good : Theme.warning, lineWidth: 6 * unit)
                .shadow(color: (verified ? Theme.good : Theme.warning).opacity(0.8), radius: 5 * unit)
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
nonisolated private struct FrameOutline: InsettableShape {
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

/// Draws `Silverside.rip_btn.svg` from the design's CSS numbers: a 256-unit square with a metal
/// frame around a 238-unit tile. `time` (nil when still) turns the disc, bounces the bars,
/// and pulses the beam.
struct RipArt {
    var time: TimeInterval?

    static let side: CGFloat = 256
    static let frameRadius: CGFloat = 57
    static let blue = Color(hex: 0x5ab0ff)
    private static let navy = Color(hex: 0x0c1733)
    /// The disc's rainbow, CSS `conic-gradient(from 200deg, ...)`.
    private static let rainbow: [Gradient.Stop] = [
        (0, 0xf2f5ff), (30, 0xff6fc4), (62, 0xffd02e), (98, 0x2fddb8), (135, 0x4d74ff), (178, 0xf2f5ff),
        (210, 0xff6fc4), (242, 0xffd02e), (278, 0x2fddb8), (318, 0x8a5cff), (360, 0xf2f5ff),
    ].map { Gradient.Stop(color: Color(hex: $0.1), location: $0.0 / 360) }
    private static let barHeights: [CGFloat] = [16, 34, 24, 50, 28, 40, 18]

    func draw(in context: inout GraphicsContext, size: CGFloat) {
        context.scaleBy(x: size / Self.side, y: size / Self.side)
        frame(&context)
        context.translateBy(x: 9, y: 9)
        context.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: 238, height: 238), cornerRadius: 49))
        context.fill(
            Path(CGRect(x: 0, y: 0, width: 238, height: 238)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0x21407a), location: 0), .init(color: Self.navy, location: 0.72),
                ]),
                center: CGPoint(x: 119, y: 66.64), startRadius: 0, endRadius: 208.6))
        disc(&context)
        beam(&context)
        bars(&context)
        arm(&context)
        context.fill(
            Path(CGRect(x: 0, y: 0, width: 238, height: 238)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.14), location: 0), .init(color: .white.opacity(0), location: 0.38),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: 238)))
    }

    /// The metal frame: CSS `linear-gradient(145deg, ...)` over the 256-unit square.
    private func frame(_ context: inout GraphicsContext) {
        let angle = 145 * Double.pi / 180
        let half = Self.side * (abs(sin(angle)) + abs(cos(angle))) / 2
        let dx = sin(angle) * half
        let dy = -cos(angle) * half
        context.fill(
            Path(roundedRect: CGRect(x: 0, y: 0, width: Self.side, height: Self.side), cornerRadius: Self.frameRadius),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0xf4f5f8), location: 0), .init(color: Color(hex: 0xa9aeb8), location: 0.38),
                    .init(color: Color(hex: 0xeef0f3), location: 0.58), .init(color: Color(hex: 0x7b808a), location: 1),
                ]), startPoint: CGPoint(x: 128 - dx, y: 128 - dy), endPoint: CGPoint(x: 128 + dx, y: 128 + dy)))
    }

    /// The disc at an angle, with its edge, grooves, hub, and the blue arc. It turns while ripping.
    private func disc(_ context: inout GraphicsContext) {
        let center = CGPoint(x: 119, y: 191)
        let rx: CGFloat = 153
        let ry: CGFloat = 75
        let shape = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - rx, y: 199 - ry, width: 2 * rx, height: 2 * ry)),
            with: .color(Color(hex: 0x6f7786)))
        // Within one turn: the time is seconds since 2001, and macOS 15 draws a conic gradient
        // at an angle of billions of degrees as its first color only (a white disc).
        let turn = time.map { (-$0 * 90).truncatingRemainder(dividingBy: 360) } ?? 0
        context.fill(
            shape,
            with: .conicGradient(Gradient(stops: Self.rainbow), center: center, angle: .degrees(110 + turn)))
        context.drawLayer { layer in
            layer.clip(to: shape)
            // repeating-radial-gradient: a 1-unit white ring at 12% every 5 units, squashed as the disc.
            var rings = Path()
            for k in 0...Int(rx / 5) {
                let r = CGFloat(k) * 5 + 0.5
                rings.addEllipse(
                    in: CGRect(x: center.x - r, y: center.y - r * ry / rx, width: 2 * r, height: 2 * r * ry / rx))
            }
            layer.stroke(rings, with: .color(.white.opacity(0.12)), lineWidth: 0.7)
            // inset 0 2px 0 white: a thin light along the top edge
            var crescent = Path(CGRect(x: -60, y: 90, width: 360, height: 210))
            crescent.addEllipse(in: CGRect(x: center.x - rx, y: center.y - ry + 2, width: 2 * rx, height: 2 * ry))
            layer.fill(crescent, with: .color(.white.opacity(0.7)), style: FillStyle(eoFill: true))
        }
        let hub: [(CGFloat, CGFloat, Color)] = [
            (48, 23, Color(hex: 0xe2e7f0).opacity(0.88)), (29, 14, Color(hex: 0xb4bac6)), (13, 6, Self.navy),
        ]
        for (index, (hx, hy, color)) in hub.enumerated() {
            let rect = CGRect(x: center.x - hx, y: center.y - hy, width: 2 * hx, height: 2 * hy)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            if index == 0 {
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: 1, dy: 1)), with: .color(.white.opacity(0.8)), lineWidth: 2)
            }
        }
        // The top and right borders of a 170 x 84 ellipse, from its upper-left to its lower-right diagonal.
        let arc = Path { path in
            let ax: CGFloat = 84.09
            let ay: CGFloat = 41.09
            for step in 0...90 {
                let t = (225 + Double(step) * 2) * Double.pi / 180
                let point = CGPoint(x: center.x + ax * cos(t), y: center.y + ay * sin(t))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        context.stroke(arc, with: .color(Self.blue.opacity(0.7)), lineWidth: 1.82)
    }

    /// The laser's light and its spot on the disc. Both pulse while ripping.
    private func beam(_ context: inout GraphicsContext) {
        let pulse = time.map { 0.85 + 0.15 * sin($0 * 6) } ?? 0.7
        let spot = CGPoint(x: 185, y: 164.5)
        context.fill(
            Path(ellipseIn: CGRect(x: spot.x - 19, y: spot.y - 13.5, width: 38, height: 27)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Self.blue.opacity(0.55 * pulse / 0.7), location: 0.3),
                    .init(color: Self.blue.opacity(0.25 * pulse / 0.7), location: 0.6),
                    .init(color: Self.blue.opacity(0), location: 1),
                ]), center: spot, startRadius: 0, endRadius: 19))
        context.fill(Path(ellipseIn: CGRect(x: 175, y: 160, width: 20, height: 9)), with: .color(.white))
        var cone = Path()
        cone.addLines([
            CGPoint(x: 169, y: 70), CGPoint(x: 201, y: 70), CGPoint(x: 187.4, y: 165), CGPoint(x: 182.6, y: 165),
        ])
        cone.closeSubpath()
        var light = context
        light.opacity = pulse
        light.fill(
            cone,
            with: .linearGradient(
                Gradient(colors: [Self.blue.opacity(0.2), Self.blue]), startPoint: CGPoint(x: 0, y: 70),
                endPoint: CGPoint(x: 0, y: 165)))
    }

    /// The level bars over the spot: white when still. While ripping they bounce, and take
    /// the progress bar's colors, which drift along the bars.
    private func bars(_ context: inout GraphicsContext) {
        var x: CGFloat = 158.5
        for (index, base) in Self.barHeights.enumerated() {
            var height = base
            var color = Color.white
            if let time {
                color = Self.sheen(at: Double(index) / Double(Self.barHeights.count) - time * 0.25)
                let wave = abs(sin(time * (4.1 + Double(index) * 0.73) + Double(index) * 1.9))
                height = 12 + (52 - 12) * CGFloat(wave) * (0.5 + base / 100)
            }
            let bar = CGRect(x: x, y: 158 - height, width: 5, height: height)
            for (grow, alpha) in [(5.5, 0.06), (4.0, 0.1), (2.5, 0.14)] {
                context.fill(
                    Path(roundedRect: bar.insetBy(dx: -grow, dy: -grow), cornerRadius: 2.5 + grow),
                    with: .color((time == nil ? Self.blue : color).opacity(alpha * (time == nil ? 1 : 1.6))))
            }
            context.fill(
                Path(roundedRect: bar.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(Color(hex: 0x0b1530)))
            context.fill(Path(roundedRect: bar, cornerRadius: 2.5), with: .color(color))
            x += 8
        }
    }

    /// A color of `Theme.sheenColors`, taken round as a loop: 0 and 1 are the first color.
    private static func sheen(at position: Double) -> Color {
        let colors = Theme.sheenColors
        let place = (position - position.rounded(.down)) * Double(colors.count)
        let index = Int(place) % colors.count
        return colors[index].mix(with: colors[(index + 1) % colors.count], by: place - place.rounded(.down))
    }

    /// The arm from the top left, its three lights (lit in turn while ripping), and the head.
    private func arm(_ context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.translateBy(x: 185, y: 64)
            layer.rotate(by: .degrees(32))
            layer.translateBy(x: -185, y: -64)
            layer.fill(
                Path(roundedRect: CGRect(x: 5, y: 42, width: 200, height: 44), cornerRadius: 22),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(hex: 0xfdfdfe), location: 0),
                        .init(color: Color(hex: 0xc9cdd6), location: 0.42),
                        .init(color: Color(hex: 0x8a909b), location: 0.56),
                        .init(color: Color(hex: 0xe6e8ec), location: 1),
                    ]), startPoint: CGPoint(x: 0, y: 42), endPoint: CGPoint(x: 0, y: 86)))
            for (index, x) in [119.5, 131.5, 143.5].enumerated() {
                let lit = time.map { Int($0 * 4) % 3 == index } ?? true
                layer.fill(
                    Path(ellipseIn: CGRect(x: x - 2.5, y: 61.5, width: 5, height: 5)),
                    with: .color(Self.blue.opacity(lit ? 1 : 0.35)))
            }
        }
        // box-shadow 0 6px 18px blue: a glow under the head
        context.fill(
            Path(ellipseIn: CGRect(x: 185 - 41, y: 70 - 41, width: 82, height: 82)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Self.blue.opacity(0.55), location: 0.341),
                    .init(color: Self.blue.opacity(0.275), location: 0.561),
                    .init(color: Self.blue.opacity(0), location: 1),
                ]), center: CGPoint(x: 185, y: 70), startRadius: 0, endRadius: 41))
        sphere(
            &context, center: CGPoint(x: 185, y: 64), radius: 23,
            stops: [(0xffffff, 0), (0xc9cdd5, 0.45), (0x6f7580, 1)])
        sphere(
            &context, center: CGPoint(x: 185, y: 64), radius: 13,
            stops: [(0xe6f7ff, 0), (0x5ab0ff, 0.38), (0x0b2a66, 1)])
    }

    /// A ball lit from the top left: CSS `radial-gradient(circle at 38% 32%, ...)`, which
    /// reaches the farthest corner of the ball's box.
    private func sphere(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, stops: [(Int, CGFloat)]) {
        let light = CGPoint(x: center.x - 0.24 * radius, y: center.y - 0.36 * radius)
        let reach = hypot(center.x + radius - light.x, center.y + radius - light.y)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
            with: .radialGradient(
                Gradient(stops: stops.map { Gradient.Stop(color: Color(hex: $0.0), location: $0.1) }), center: light,
                startRadius: 0, endRadius: reach))
    }
}

extension Color {
    /// A color from its sRGB hex value, as in CSS: `Color(hex: 0x5ab0ff)`.
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}
