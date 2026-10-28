import SilversideKit
import SwiftUI

/// Picks one of the MusicBrainz releases that have the disc.
struct ReleasePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var disc: DiscInfo
    var choose: (MusicBrainzRelease) -> Void
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which release is this disc from?").font(.headline)
            Text(
                disc.isFuzzy
                    ? "MusicBrainz does not know this disc ID. These releases have nearly the same TOC."
                    : "Several releases in MusicBrainz have this disc. The choice is kept for the other discs of the release."
            )
            .foregroundStyle(.secondary)
            List(disc.releases, id: \.id, selection: $selected) { release in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.artist) – \(release.title)").font(.body.weight(.medium))
                    Text(details(of: release)).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(release.id)
            }
            .frame(minHeight: 220)
            if disc.isFuzzy {
                Link(
                    "Add this disc ID to the right release in MusicBrainz",
                    destination: MusicBrainzRelease.submissionURL(for: disc.toc)
                )
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Release") {
                    if let release = disc.releases.first(where: { $0.id == selected }) { choose(release) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 440)
        .onAppear { selected = disc.release?.id ?? disc.releases.first?.id }
    }

    private func details(of release: MusicBrainzRelease) -> String {
        var parts = [String]()
        if let date = release.date { parts.append(date) }
        if let country = release.country { parts.append(country) }
        if release.media.count > 1 {
            if let medium = release.medium(for: disc.toc) {
                parts.append("disc \(medium.position) of \(release.media.count)")
            } else {
                parts.append("\(release.media.count) discs")
            }
        }
        if let barcode = release.barcode, !barcode.isEmpty { parts.append("barcode \(barcode)") }
        let labels = release.labels.compactMap { label in
            [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        parts.append(contentsOf: labels)
        if let status = release.status, status != "Official" { parts.append(status.lowercased()) }
        if let disambiguation = release.disambiguation, !disambiguation.isEmpty { parts.append(disambiguation) }
        return parts.joined(separator: " · ")
    }
}

/// The rip's log, as `silverside rip` prints it.
struct RipLogView: View {
    @Environment(\.dismiss) private var dismiss
    var run: RipRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rip Log").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            LogText(lines: run?.log ?? ["No rip yet."])
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private var text: String {
        guard let run else { return "No rip yet." }
        return run.log.joined(separator: "\n")
    }
}

/// Lines of a log, in a box that follows the newest line.
struct LogText: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("end")
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// A repair of an earlier rip: what it does, and what it found.
struct RepairSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var run: RepairRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if run.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(isGood ? Theme.good : Theme.warning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repair · \(run.rip.title)").font(.headline)
                    Text(run.headline).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let folder = run.writtenFolder {
                    Button("Show in Finder") { model.revealInFinder(folder) }
                }
                if run.isRunning {
                    Button("Stop") { run.stop() }.help("Stop after the read under way. Nothing is written.")
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            LogText(lines: run.log)
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private var isGood: Bool {
        switch run.outcome {
        case .verified, .repaired: run.phase == .finished
        default: false
        }
    }
}

/// A drive test or a cache measurement from Settings › Drives: the checks and their results.
struct DriveTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    var run: DriveTestRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if run.isRunning { ProgressView().controlSize(.small) }
                Text("\(run.title) · \(run.slot.name)").font(.headline)
                Spacer()
                if run.report != nil {
                    Button("Save Report…") { run.saveReport() }
                        .help("Save the checks and the drive's registry entries as JSON, for a bug report")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(run.isRunning)
            }
            if let report = run.report {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(report.checks, id: \.name) { check in
                        GridRow {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.passed ? Theme.good : Theme.bad)
                            Text(check.name)
                            Text(check.result).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            Text("\(check.milliseconds) ms").foregroundStyle(.secondary).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            LogText(lines: run.log)
        }
        .padding(16)
        .frame(width: 680, height: run.report == nil ? 320 : 540)
    }
}

/// The library work under way: encoding a set's discs, or bringing them up to date.
struct LibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    var run: LibraryRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if run.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: run.problems == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(run.problems == 0 ? Theme.good : Theme.warning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.headline)
                    Text(run.headline).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if run.isRunning {
                    Button("Stop") { run.stop() }.help("Stop after the disc under way")
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            LogText(lines: run.log)
        }
        .padding(16)
        .frame(width: 720, height: 420)
    }
}

/// After a rip whose HDCD codes change the audio, before encoding: decode them, or keep the
/// audio as pressed. The advice follows the format (`AudioFormat.recommendsHDCDDecode`).
struct HDCDQuestionSheet: View {
    @Environment(AppModel.self) private var model
    var rip: RipRun
    var question: RipRun.HDCDQuestion
    @State private var remembers = false

    var body: some View {
        let format = question.format
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("HDCD").resizable().scaledToFit().frame(height: 22)
                Text("“\(question.album)” uses HDCD").font(.title3.bold())
            }
            Text(
                (question.features.map { "Its codes ask for \($0). " } ?? "")
                    + "Few players decode HDCD, so Silverside can decode it now."
            )
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    .init(
                        "**Decode:** the audio as an HDCD player plays it, in "
                            + (format.isLossless
                                ? "\(format.wideBits)-bit \(format.name) files" : "\(format.name) files")
                            + (HDCDSizeWarning.growth(for: format).map { ", \($0)" } ?? " of the same size")
                            + ". They are 6 dB quieter; ReplayGain makes up the level."))
                Text(
                    .init(
                        format.isLossless
                            ? "**Keep as pressed:** files bit for bit the disc, with the codes in them. Decode HDCD… can make a decoded copy later."
                            : "**Keep as pressed:** the audio as a player without a decoder plays it."))
            }
            .fixedSize(horizontal: false, vertical: true)
            if let note = Self.note(for: format) {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Use this answer for every HDCD disc (Settings › Encoding)", isOn: $remembers)
            HStack {
                Spacer()
                if question.recommendsDecoding {
                    Button("Keep as Pressed") { answer(decodes: false) }
                    Button("Decode") { answer(decodes: true) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Decode") { answer(decodes: true) }
                    Button("Keep as Pressed") { answer(decodes: false) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// Why the default button is the advice, where that is not plain.
    static func note(for format: AudioFormat) -> String? {
        switch format {
        case .aac, .mp3: "\(format.name) files lose the codes, so they cannot be decoded later."
        case .aiff, .wav: "For \(format.name), keeping the audio as pressed is the usual choice."
        case .flac, .alac: nil
        }
    }

    private func answer(decodes: Bool) {
        if remembers { model.settings.hdcd = decodes ? .decode : .keep }
        rip.answerHDCD(decodes: decodes)
    }
}

/// After a rip with tracks that have pre-emphasis, before encoding: take it out, as a CD
/// player does, or keep the audio as pressed. De-emphasizing is the advice for every format.
struct PreEmphasisQuestionSheet: View {
    @Environment(AppModel.self) private var model
    var rip: RipRun
    var question: RipRun.PreEmphasisQuestion
    @State private var remembers = false

    var body: some View {
        let format = question.format
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(question.album)” has pre-emphasis").font(.title3.bold())
            Text(
                (question.everyTrack ? "Every track was" : "Some tracks were")
                    + " mastered with pre-emphasis, a treble boost that a CD player takes out again. Few other players"
                    + " take it out, so they play "
                    + (question.everyTrack ? "the tracks" : question.tracks) + " too bright."
            )
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    .init(
                        "**De-emphasize:** the audio as a CD player plays it, in "
                            + (format.isLossless
                                ? "\(format.wideBits)-bit \(format.name) files" : "\(format.name) files")
                            + ", tagged DE_EMPHASIZED=yes. The other tracks stay as they are."))
                Text(
                    .init(
                        "**Keep as pressed:** files bit for bit the disc, tagged PRE_EMPHASIS=yes, for a player that takes it out itself."
                    ))
            }
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Use this answer for every disc with pre-emphasis (Settings › Encoding)", isOn: $remembers)
            HStack {
                Spacer()
                Button("Keep as Pressed") { answer(deEmphasizes: false) }
                Button("De-emphasize") { answer(deEmphasizes: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func answer(deEmphasizes: Bool) {
        if remembers { model.settings.preEmphasis = deEmphasizes ? .deEmphasize : .keep }
        rip.answerPreEmphasis(deEmphasizes: deEmphasizes)
    }
}

/// As a rip of a disc with a data track starts (an Enhanced CD's extras for a computer): save
/// it, or rip the audio only. Saving is the advice; it does not change the audio.
struct DataTrackQuestionSheet: View {
    @Environment(AppModel.self) private var model
    var rip: RipRun
    var question: RipRun.DataTrackQuestion
    @State private var remembers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(question.album)” has a data track").font(.title3.bold())
            Text(
                (question.isEnhanced ? "This is an Enhanced CD: after the music, it" : "This disc")
                    + " has a data track with extras for a computer, such as videos, pictures, lyrics, or a program."
                    + " Saving it takes about a minute and "
                    + ByteCountFormatter.string(fromByteCount: Int64(question.bytes), countStyle: .file) + "."
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(
                .init(
                    "**Save** puts a disc image of the track, `Data track.iso`, in the album's folder, and a `Data track`"
                        + " folder with the files on it, ready to open. The music is ripped the same either way.")
            )
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Use this answer for every disc with a data track (Settings › Ripping)", isOn: $remembers)
            HStack {
                Spacer()
                Button("Audio Only") { answer(saves: false) }
                Button("Save") { answer(saves: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func answer(saves: Bool) {
        if remembers { model.settings.dataTracks = saves ? .save : .skip }
        rip.answerDataTracks(saves: saves)
    }
}

/// Decode HDCD… for an earlier rip: a decoded album beside the album, or in place of its files.
struct HDCDDecodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var rip: RecentRip
    @State private var beside = true
    @State private var format = AudioFormat.flac
    /// What the copy's album title ends with, after a space: "(HDCD)", or "(HDCD AAC)".
    @State private var suffix = "(HDCD)"

    private var album: String { rip.report.release?.title ?? rip.title }
    private var trimmedSuffix: String { suffix.trimmingCharacters(in: .whitespaces) }

    /// The album's files can be replaced only when it is encoded.
    private var encoding: RipReport.Encoding? { rip.report.encoding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("HDCD").resizable().scaledToFit().frame(height: 22)
                Text("Decode HDCD").font(.title3.bold())
            }
            if let text = rip.report.hdcdText { Text(text).fixedSize(horizontal: false, vertical: true) }
            Picker("Write", selection: $beside) {
                Text("A copy beside the album, as “\(album) \(trimmedSuffix)”").tag(true)
                Text("In place of the album's files").tag(false)
                    .disabled(encoding == nil)
            }
            .pickerStyle(.radioGroup)
            if beside {
                HStack(spacing: 6) {
                    Text("Title").frame(width: 50, alignment: .leading)
                    Text(album).lineLimit(1).foregroundStyle(.secondary)
                    TextField("(HDCD)", text: $suffix).frame(width: 140)
                }
                .help(
                    "The copy's album title is the album's with this added, and so is its folder's name. It must not be empty: the copy needs a name of its own."
                )
                Picker("Format", selection: $format) {
                    ForEach(AudioFormat.allCases.filter { $0 != .mp3 || MP3Encoder.lame() != nil }, id: \.self) {
                        Text($0.name).tag($0)
                    }
                }
                .fixedSize()
                HDCDSizeWarning(format: format)
                Text(
                    "The copy has its own folder and album title, tagged HDCD=decoded, so players list it next to the album as it is. "
                        + (rip.hasAudio
                            ? "It is made from the rip's WAV files."
                            : "It is made from the album's files, each checked first against the rip.")
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let encoding {
                HDCDSizeWarning(format: encoding.format)
                Text(
                    "The album's \(encoding.format.name) files become \(encoding.format.isLossless ? "\(encoding.format.wideBits)-bit, " : "")tagged HDCD=decoded, with ReplayGain measured again. The audio as pressed is gone from the library"
                        + (rip.hasAudio
                            ? ", but stays in the rip's WAV files." : "; only a new rip of the disc gets it back.")
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Decode") {
                    dismiss()
                    model.startHDCDDecode(
                        rip, beside: beside, format: beside ? format : encoding?.format ?? format,
                        suffix: " " + trimmedSuffix)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(beside && trimmedSuffix.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { format = encoding?.format ?? model.settings.format }
    }
}

/// How much larger decoded files are than the 16-bit ones, as a warning; nothing for AAC and
/// MP3, whose size the decode does not change.
struct HDCDSizeWarning: View {
    var format: AudioFormat

    /// Measured on *Dozin' at the Knick*, disc 1, with Apple's encoders: 20-bit FLAC grew 5% (it
    /// stores the bits a block does not use for almost nothing), 20-bit Apple Lossless 29% (it does not).
    static func text(for format: AudioFormat) -> String? {
        switch format {
        case .flac: "20-bit FLAC files are a little larger than 16-bit ones: about 5%."
        case .alac: "20-bit Apple Lossless files are larger than 16-bit ones: about a third."
        case .aiff, .wav: "24-bit \(format.name) files are half again as large as 16-bit ones."
        case .aac, .mp3: nil
        }
    }

    /// How much larger decoded files are: "about 5% larger". Nil for AAC and MP3.
    static func growth(for format: AudioFormat) -> String? {
        switch format {
        case .flac: "about 5% larger"
        case .alac: "about a third larger"
        case .aiff, .wav: "half again as large"
        case .aac, .mp3: nil
        }
    }

    var body: some View {
        if let text = Self.text(for: format) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
