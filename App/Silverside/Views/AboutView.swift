import AppKit
import SilversideKit
import SwiftUI

/// The About window: the icon on a hero with a disc's grooves, the disc's rainbow
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
                    Text("Version \(version)").font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
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

    /// "0.9 (1) · 536e697-dirty": the version, the build, and the Git commit, with "-dirty" if the
    /// build had changes that were not committed.
    private var version: String {
        let info = Bundle.main.infoDictionary
        var text = info?["CFBundleShortVersionString"] as? String ?? SilversideVersion.string
        if let build = info?["CFBundleVersion"] as? String { text += " (\(build))" }
        // A release (an archive) leaves out the commit, which its Git tag names, unless it had
        // changes that were not committed. The reports and the log name it either way.
        let archive = info?["SilversideArchive"] as? Bool == true
        if let commit = SilversideVersion.commit, !archive || commit.hasSuffix("-dirty") { text += " · \(commit)" }
        return text
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    /// Each disc counts once, however many times it was ripped or repaired, with its best
    /// rip's verified tracks.
    private var discs: (count: Int, verifiedTracks: Int) {
        // Every rip in the history counts, also one whose files were moved or deleted.
        let byDisc = Dictionary(grouping: model.allRips, by: \.report.toc)
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

/// The app's icon with a disc's grooves around it, for the About window and the welcome.
/// The field matches the icon's own background: warm paper in light mode, dark brown in dark.
struct Hero: View {
    var height: CGFloat = 232
    var iconSize: CGFloat = 190
    @Environment(\.colorScheme) private var colorScheme

    /// The middle and the edge of the field. The middle is a little lighter than the icon's
    /// background, so that the icon stands out from it.
    private var field: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.25, green: 0.19, blue: 0.12), Color(red: 0.06, green: 0.045, blue: 0.03)]
            : [Color(red: 0.97, green: 0.94, blue: 0.87), Color(red: 0.84, green: 0.78, blue: 0.65)]
    }

    private var grooves: Color {
        colorScheme == .dark ? .white.opacity(0.05) : Color(red: 0.35, green: 0.27, blue: 0.15).opacity(0.08)
    }

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.25), radius: 18, y: 10)
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
                            Gradient(colors: field), center: center, startRadius: 20, endRadius: 300))
                    let outer = hypot(size.width, size.height)
                    for radius in stride(from: CGFloat(110), through: outer, by: 7) {
                        let ring = Path(
                            ellipseIn: CGRect(
                                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(grooves), lineWidth: 1)
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
            "[XLD](https://tmkk.undo.jp/xld/index_e.html)",
            "by tmkk, the careful CD ripper for the Mac, was an inspiration. Silverside uses no code from it."
        ),
        (
            "[cyanrip](https://github.com/cyanreg/cyanrip)",
            "by Lynne, a ripper built for today's tools, was an inspiration too. No code from it either."
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
            "[FFmpeg](https://ffmpeg.org)'s HDCD decoder",
            "finds and decodes the HDCD codes in a rip. Chris Moeller wrote it from Christopher Key's HDCD library, with work by Gumboot and Burt P. Silverside includes it under its BSD license (see License)."
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

/// The license, from the copy of LICENSE in the app's bundle, and the HDCD decoder's.
private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        let own =
            Bundle.main.url(forResource: "LICENSE", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? SilversideLicense.text
        return own.trimmingCharacters(in: .newlines)
            + "\n\nThe HDCD decoder from FFmpeg (libavfilter/af_hdcd.c), which Silverside includes:\n\n"
            + SilversideLicense.hdcdDecoder
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
