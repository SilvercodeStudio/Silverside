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
                    Text(Self.details(of: release, toc: disc.toc)).font(.callout).foregroundStyle(.secondary)
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
                Button("New Release in MusicBrainz…") {
                    if let release = disc.releases.first(where: { $0.id == selected }) {
                        ResultChips.openNewRelease(copying: release, toc: disc.toc)
                    }
                }
                .disabled(selected == nil)
                .help(ResultChips.newReleaseHelp.replacingOccurrences(of: "this one", with: "the selected one"))
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

    /// "2003-11-18 · US · disc 1 of 2 · barcode … · Capitol CDP 7243 5 95713 2 4": what tells editions apart.
    static func details(of release: MusicBrainzRelease, toc: TOC) -> String {
        var parts = [String]()
        if let date = release.date { parts.append(date) }
        if let country = release.country { parts.append(country) }
        if release.media.count > 1 {
            if let medium = release.medium(for: toc) {
                parts.append("disc \(medium.position) of \(release.media.count)")
            } else {
                parts.append("\(release.media.count) discs")
            }
        }
        // A set of CDs only goes without saying; "CD + Blu-ray" or "HDCD" tells releases apart.
        if !release.isCDsOnly { parts.append(release.formats) }
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

/// Change Release: another release of MusicBrainz's for an earlier rip's disc.
struct ChangeReleaseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var rip: RecentRip
    @State private var releases: [MusicBrainzRelease] = []
    @State private var isFuzzy = false
    @State private var isLookingUp = true
    @State private var failure: String?
    @State private var selected: String?

    private var toc: TOC? { try? TOC(ctdbTOCString: rip.report.toc) }
    private var current: MusicBrainzRelease? { rip.report.release }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change the release of “\(rip.title)”").font(.headline)
            Text(
                "The encoded files get the release's names, tags, and cover, and are renamed to match. The audio "
                    + "does not change. Names you changed on this rip go back to the release's. The other discs of a "
                    + "set keep their release."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let current, current.isManual {
                Text("This rip has no MusicBrainz release: its names were typed in.").font(.callout)
            }
            if isLookingUp {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking up the disc in MusicBrainz…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if releases.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.map { "The lookup failed: \($0)" } ?? "MusicBrainz has no release with this disc.")
                    if let toc, failure == nil {
                        Link(
                            "Add this disc ID to a release in MusicBrainz",
                            destination: MusicBrainzRelease.submissionURL(for: toc))
                        Text("Then click Look Up Again.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            } else {
                if isFuzzy {
                    Text("MusicBrainz does not know this disc ID. These releases have nearly the same TOC.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                List(releases, id: \.id, selection: $selected) { release in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "\(release.artist) – \(release.title)"
                                + (release.id == current?.id ? " (this rip's release)" : "")
                        )
                        .font(.body.weight(.medium))
                        if let toc {
                            Text(ReleasePickerSheet.details(of: release, toc: toc)).font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(release.id)
                }
                .frame(minHeight: 220)
            }
            HStack {
                Button("Look Up Again") { Task { await lookUp(fresh: true) } }
                    .disabled(isLookingUp)
                    .help("Ask MusicBrainz again, for a release or a disc ID added since the rip")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change Release") {
                    if let release = releases.first(where: { $0.id == selected }) {
                        model.changeRelease(of: rip, to: release)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || selected == current?.id || !model.canChangeRelease(rip))
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .task { await lookUp(fresh: false) }
    }

    /// The releases with the disc, from the cache unless `fresh`: the rip looked the disc up.
    private func lookUp(fresh: Bool) async {
        guard let toc else { return }
        isLookingUp = true
        failure = nil
        do {
            let result = try await ReleaseLookup.find(toc: toc, mcn: rip.report.mcn, useCache: !fresh)
            releases = result.ranked
            isFuzzy = !result.isExact
        } catch {
            failure = "\(error)"
        }
        isLookingUp = false
        if !releases.contains(where: { $0.id == selected }) {
            selected = releases.first { $0.id != current?.id }?.id
        }
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

/// After a rip of a DTS-CD, before encoding: the album as the disc has it with a decoded copy
/// beside it (the advice), the decode alone, or the stream alone. Without ffmpeg, it says how
/// to get it, and the stream is kept.
struct DTSQuestionSheet: View {
    @Environment(AppModel.self) private var model
    var rip: RipRun
    var question: RipRun.DTSQuestion
    @State private var choice = DTSChoice.decode
    @State private var remembers = false

    var body: some View {
        let format = question.format
        let decoded = DiscEncoder.surroundFormat(for: format)
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(question.album)” is a DTS-CD").font(.title3.bold())
            Text(
                "Its tracks hold surround sound coded as DTS, for a player or receiver with a DTS decoder. Other"
                    + " players play it as loud static."
            )
            .fixedSize(horizontal: false, vertical: true)
            if question.canDecode {
                Picker("Encode", selection: $choice) {
                    if format.isLossless {
                        Text("The album as the disc has it, and a decoded copy beside it").tag(DTSChoice.decode)
                    }
                    Text("The decoded album only").tag(DTSChoice.decodeOnly)
                    Text(format.isLossless ? "The DTS stream only" : "Nothing: keep the rip").tag(DTSChoice.keep)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(
                    "ffmpeg decodes the stream into \(decoded.name) files with every channel, tagged DTS=decoded."
                        + (format.isLossless
                            ? " The album as the disc has it is the stream bit for bit, for a DTS receiver."
                            : " \(format.name) would turn the stream itself into noise.")
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Toggle("Use this answer for every DTS-CD (Settings › Encoding)", isOn: $remembers)
            } else {
                Text(
                    (format.isLossless
                        ? "The files keep the stream as the disc has it, bit for bit."
                        : "\(format.name) would turn the stream into noise, so the rip is kept, not encoded.")
                        + " To decode it into \(decoded.name) files with every channel, install ffmpeg (in Terminal:"
                        + " brew install ffmpeg), then choose Decode DTS… for this rip."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if question.canDecode {
                    Button("Encode") { answer(choice) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("OK") { rip.answerDTS(.keep) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { choice = format.isLossless ? .decode : .decodeOnly }
    }

    private func answer(_ choice: DTSChoice) {
        if remembers { model.settings.dts = choice }
        rip.answerDTS(choice)
    }
}

/// Decode DTS… for an earlier rip, with ffmpeg: a decoded album beside the album, or in place
/// of its files.
struct DTSDecodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var rip: RecentRip
    @State private var beside = true
    @State private var format = AudioFormat.flac
    /// What the copy's album title ends with, after a space.
    @State private var suffix = "(DTS 5.1)"
    @State private var ffmpeg = FFmpeg.program()

    private var album: String { rip.report.release?.title ?? rip.title }
    private var trimmedSuffix: String { suffix.trimmingCharacters(in: .whitespaces) }
    private var encoding: RipReport.Encoding? { rip.report.encoding }
    /// The album's files can be replaced when it is encoded in a format that holds surround sound.
    private var canReplace: Bool { encoding.map { AudioEncoder.holdsSurround($0.format) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decode DTS").font(.title3.bold())
            if let text = rip.report.dtsText { Text(text).fixedSize(horizontal: false, vertical: true) }
            if ffmpeg == nil {
                Text(
                    "Decoding needs ffmpeg, which is not installed. In Terminal: brew install ffmpeg. This window"
                        + " finds it as soon as it is there."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Write", selection: $beside) {
                Text("A copy beside the album, as “\(album) \(trimmedSuffix)”").tag(true)
                Text("In place of the album's files").tag(false).disabled(!canReplace)
            }
            .pickerStyle(.radioGroup)
            if beside {
                HStack(spacing: 6) {
                    Text("Title").frame(width: 50, alignment: .leading)
                    Text(album).lineLimit(1).foregroundStyle(.secondary)
                    TextField("(DTS 5.1)", text: $suffix).frame(width: 140)
                }
                .help(
                    "The copy's album title is the album's with this added, and so is its folder's name. It must not be empty: the copy needs a name of its own."
                )
                Picker("Format", selection: $format) {
                    ForEach(AudioFormat.allCases.filter(AudioEncoder.holdsSurround), id: \.self) {
                        Text($0.name).tag($0)
                    }
                }
                .fixedSize()
                Text(
                    "The copy has its own folder and album title, tagged DTS=decoded, so players list it next to the album as it is. "
                        + (rip.hasAudio
                            ? "It is made from the rip's WAV files."
                            : "It is made from the album's files, each checked first against the rip.")
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let encoding {
                Text(
                    "The album's \(encoding.format.name) files become the decode, tagged DTS=decoded, with ReplayGain. The DTS stream is gone from the library"
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
                    model.startDTSDecode(
                        rip, beside: beside, format: beside ? format : encoding?.format ?? format,
                        suffix: " " + trimmedSuffix)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ffmpeg == nil || (beside && trimmedSuffix.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { format = DiscEncoder.surroundFormat(for: encoding?.format ?? model.settings.format) }
        .task {
            // Look for ffmpeg every 2 seconds, so an install in Terminal turns Decode on.
            while ffmpeg == nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                ffmpeg = FFmpeg.program()
            }
        }
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
