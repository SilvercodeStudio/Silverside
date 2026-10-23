import AppKit
import SilversideKit
import SwiftUI

/// The About window: the icon on a dark hero with a disc's grooves, the disc's rainbow
/// under it, the version, what the user has ripped, and the services that make it work.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @State private var drivesKnown = 0
    @State private var acknowledgmentsShown = false

    static let website = URL(string: "https://silverside.app")!

    var body: some View {
        VStack(spacing: 0) {
            Hero()
            Theme.sheen.frame(height: 3)
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text("Silverside").font(.system(size: 34, weight: .bold))
                    Text("Version \(version)").font(.title3).foregroundStyle(.secondary)
                }
                Text("Accurate CD ripping for the Mac.").font(.title3)
                stats
                credits
                HStack(spacing: 12) {
                    Button("Acknowledgments…") { acknowledgmentsShown = true }
                    Button("Website") { NSWorkspace.shared.open(Self.website) }
                }
                .controlSize(.large)
                .padding(.top, 6)
                Text(copyright).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .frame(width: 460)
        .task { drivesKnown = (try? DriveProfileStore().profiles.count) ?? 0 }
        .sheet(isPresented: $acknowledgmentsShown) { AcknowledgmentsSheet() }
        #if DEBUG
            // `-showAcknowledgments 1` (and `-showLicense 1`) open the sheets, for screenshots.
            .onAppear { acknowledgmentsShown = UserDefaults.standard.bool(forKey: "showAcknowledgments") }
        #endif
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? SilversideVersion.string
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    /// Each disc counts once, however many times it was ripped or repaired, with its best
    /// rip's verified tracks.
    private var discs: (count: Int, verifiedTracks: Int) {
        let byDisc = Dictionary(grouping: model.recentRips, by: \.report.toc)
        return (byDisc.count, byDisc.values.reduce(0) { $0 + ($1.map(\.verifiedCount).max() ?? 0) })
    }

    @ViewBuilder private var stats: some View {
        let discs = discs
        if discs.count > 0 {
            HStack(spacing: 10) {
                StatTile(value: discs.count, label: discs.count == 1 ? "disc ripped" : "discs ripped")
                StatTile(
                    value: discs.verifiedTracks, label: discs.verifiedTracks == 1 ? "track verified" : "tracks verified"
                )
                // One drive is no news; the count says something only once there are several.
                if drivesKnown > 1 { StatTile(value: drivesKnown, label: "drives known") }
            }
        }
    }

    private var credits: some View {
        VStack(spacing: 4) {
            Text(
                "Verified with [AccurateRip](http://www.accuraterip.com) and [CUETools DB](http://cue.tools/wiki/CUETools_Database)."
            )
            Text(
                "Names and covers from [MusicBrainz](https://musicbrainz.org) and the [Cover Art Archive](https://coverartarchive.org)."
            )
            Text("Inspired by Exact Audio Copy.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The app's icon over a dark blue field with a disc's grooves around it, for the About
/// window and the welcome.
struct Hero: View {
    var height: CGFloat = 232
    var iconSize: CGFloat = 190

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // Only the background reaches under the title bar, so the window keeps its height.
            // Its grooves and glow center on the icon, measured from the bottom: the part
            // under the title bar is above the hero's own height.
            .background {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height - height / 2)
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 0.13, green: 0.25, blue: 0.50), Color(red: 0.04, green: 0.08, blue: 0.20),
                            ]),
                            center: center, startRadius: 20, endRadius: 300))
                    let outer = hypot(size.width, size.height)
                    for radius in stride(from: CGFloat(110), through: outer, by: 7) {
                        let ring = Path(
                            ellipseIn: CGRect(
                                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(.white.opacity(0.05)), lineWidth: 1)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

private struct StatTile: View {
    var value: Int
    var label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value.formatted()).font(.title.bold()).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Who and what Silverside builds on.
private struct AcknowledgmentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licenseShown = false

    private let entries: [(name: String, text: String)] = [
        (
            "[Exact Audio Copy](https://www.exactaudiocopy.de)",
            "by Andre Wiethoff set the standard for secure ripping that Silverside follows."
        ),
        (
            "[AccurateRip](http://www.accuraterip.com)",
            "by Illustrate keeps the checksums of other people's rips, which prove a track is accurate."
        ),
        (
            "[CUETools DB](http://cue.tools/wiki/CUETools_Database)",
            "by Grigory Chudov keeps checksums of whole discs, and the data that repairs damaged rips."
        ),
        (
            "[MusicBrainz](https://musicbrainz.org) and the [Cover Art Archive](https://coverartarchive.org),",
            "run by the MetaBrainz Foundation, provide album names and cover art, built by their volunteers."
        ),
        (
            "[LAME](https://lame.sourceforge.io)",
            "encodes MP3, when it is installed. Silverside runs it as a separate program and does not include it."
        ),
        (
            "Apple's AudioToolbox",
            "encodes FLAC, ALAC, and AAC."
        ),
        (
            "[Claude Code](https://claude.com/claude-code)",
            "by Anthropic was the coding agent that helped write Silverside."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Acknowledgments").font(.title2.bold())
            ForEach(entries, id: \.name) { entry in
                Text(.init("**\(entry.name)** \(entry.text)"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("License…") { licenseShown = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .sheet(isPresented: $licenseShown) { LicenseSheet() }
        #if DEBUG
            .onAppear { licenseShown = UserDefaults.standard.bool(forKey: "showLicense") }
        #endif
    }
}

/// The license, from the copy of LICENSE in the app's bundle.
private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? SilversideLicense.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("License").font(.title2.bold())
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 540)
    }
}
