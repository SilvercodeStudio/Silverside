import SilversideKit
import SwiftUI

/// The first launch's window: a welcome, the drives that macOS has, and the choice of what
/// a rip becomes. "Get Started" saves the choice in the settings, which the CLI shares.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var choice = Choice.flac
    /// MP3 needs the external `lame`; the window looks for it while it is open.
    @State private var lame = MP3Encoder.lame()

    static let doneKey = "welcomeDone"

    enum Choice: CaseIterable {
        case alac, flac, aac, mp3, wav

        var title: String {
            switch self {
            case .alac: "Apple Lossless"
            case .flac: "FLAC"
            case .aac: "AAC"
            case .mp3: "MP3"
            case .wav: "WAV files only"
            }
        }

        var text: String {
            switch self {
            case .alac: "An exact copy of the CD. Best for the Music app, iPhone, and other Apple devices."
            case .flac:
                "An exact copy of the CD, for most other systems and players. Apple's Music app does not play it."
            case .aac: "A fifth of the size, and most people cannot hear a difference. Plays almost everywhere."
            case .mp3: "Plays on almost anything, old or new. AAC sounds a little better at the same size."
            case .wav: "No encoding: rips stay in the rips folder as uncompressed WAV files, with no tags."
            }
        }

        var format: AudioFormat? {
            switch self {
            case .alac: .alac
            case .flac: .flac
            case .aac: .aac
            case .mp3: .mp3
            case .wav: nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Hero(height: 104, iconSize: 96)
            Theme.sheen.frame(height: 3)
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 6) {
                    Text("Welcome to Silverside").font(.system(size: 26, weight: .bold))
                    Text(
                        "Thanks for trying Silverside! It checks every track against other people's rips,\nso you know your copy is exact."
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                driveStatus
                VStack(alignment: .leading, spacing: 8) {
                    Text("What kind of files do you want?").font(.headline)
                    ForEach(Choice.allCases, id: \.self) { item in
                        ChoiceRow(
                            choice: item, isSelected: item == choice,
                            unavailable: item == .mp3 && lame == nil
                                ? "Needs the LAME encoder: install it with Homebrew (brew install lame), and this turns on."
                                : nil
                        ) { choice = item }
                    }
                    Text(
                        "Encoded albums go in \(Self.abbreviated(model.settings.library)), named and tagged from MusicBrainz."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // The likeliest snag at the first rip: Music plays or imports the disc while Silverside reads it.
                Label {
                    Text(
                        "Before the first rip, open the Music app's settings and set “When a CD is inserted” to Show CD, so that Music does not play or import the disc while Silverside reads it."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "music.note").foregroundStyle(Theme.warning)
                }
                .font(.callout)
                HStack {
                    Spacer()
                    Button("Settings…") {
                        finish()
                        openSettings()
                    }
                    Button("Get Started") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        // Wide enough that each choice's text is one line, so the window fits a 13-inch screen.
        .frame(width: 720)
        .watchingForLAME($lame)
        .onChange(of: lame) { if lame == nil && choice == .mp3 { choice = .flac } }
        .onAppear {
            // The settings' choice; at the first launch, with encoding off, FLAC is suggested.
            if model.settings.encodeAfterRip {
                choice = Choice.allCases.first { $0.format == model.settings.format } ?? .flac
                if choice == .mp3 && lame == nil { choice = .flac }
            } else if UserDefaults.standard.bool(forKey: Self.doneKey) {
                choice = .wav
            }
        }
    }

    /// The drives macOS has now, one to a line; it changes when one is connected.
    @ViewBuilder private var driveStatus: some View {
        let names = model.drives.filter { !$0.isDemo }.map(\.name)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: names.isEmpty ? "opticaldiscdrive" : "checkmark.circle.fill")
                .foregroundStyle(names.isEmpty ? Color.secondary : Theme.good)
            if names.isEmpty {
                Text("No CD drive yet. Connect one, and Silverside will find it as soon as macOS does.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(names.count == 1 ? "Found a CD drive:" : "Found \(names.count) CD drives:")
                    ForEach(names, id: \.self) { name in
                        Label(name, systemImage: "opticaldiscdrive")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func finish() {
        if let format = choice.format {
            model.settings.format = format
            model.settings.encodeAfterRip = true
        } else {
            model.settings.encodeAfterRip = false
        }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        dismiss()
    }

    private static func abbreviated(_ path: String) -> String {
        (Settings.expand(path).path as NSString).abbreviatingWithTildeInPath
    }
}

/// One choice: a radio mark, the name, and what it means; or, when it cannot be chosen yet, why.
private struct ChoiceRow: View {
    var choice: WelcomeView.Choice
    var isSelected: Bool
    var unavailable: String?
    var select: () -> Void

    var body: some View {
        // A choice that cannot be made yet is no button, so that its note stays easy to read.
        if unavailable != nil {
            row
        } else {
            Button(action: select) { row }.buttonStyle(.plain)
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .opacity(unavailable != nil ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.title).font(.body.weight(.semibold))
                    .foregroundStyle(unavailable != nil ? .secondary : .primary)
                Text(unavailable ?? choice.text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
    }
}
