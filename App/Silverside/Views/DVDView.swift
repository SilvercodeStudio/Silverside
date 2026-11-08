import AppKit
import SilversideKit
import SwiftUI
import UniformTypeIdentifiers

struct DVDView: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot
    @Bindable var dvd: DVDSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image("DiscLogoDVDAudio").resizable().scaledToFit().frame(width: 100, height: 48)
                VStack(alignment: .leading) {
                    Text(dvd.title).font(.title2.bold())
                    Text("DVD-Audio · lossless FLAC").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Inspect Again") { dvd.inspect() }.disabled(!slot.canInspectDVD)
                Button("Import Names…", action: importNames).disabled(dvd.inventory == nil || dvd.isAccessingDrive)
            }
            if let inventory = dvd.inventory {
                Picker("Audio program", selection: $dvd.selectedProgram) {
                    Text("Choose a program").tag("")
                    ForEach(inventory.presentations, id: \.id) { program in
                        Text(programLabel(program)).tag(program.id)
                    }
                }.disabled(dvd.isAccessingDrive)
                if let issue = dvd.presentation?.unsupportedReason { Text(issue).foregroundStyle(.orange) }
                ForEach(Array((inventory.titleSetIssues ?? []).enumerated()), id: \.offset) { _, issue in
                    Text("Title set \(issue.titleSet): \(issue.reason)").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    TextField(
                        "Album",
                        text: Binding(get: { dvd.metadata?.albumName ?? "" }, set: { dvd.edit("album", value: $0) })
                    )
                    .accessibilityLabel("DVD album")
                    TextField(
                        "Album artist",
                        text: Binding(
                            get: { dvd.metadata?.artistName ?? "" }, set: { dvd.edit("albumArtist", value: $0) })
                    )
                    .accessibilityLabel("DVD album artist")
                }.textFieldStyle(.roundedBorder).disabled(dvd.isAccessingDrive)
                if let program = dvd.selectedMetadata {
                    Table(program.tracks) {
                        TableColumn("#") { Text(String($0.source.number)).monospacedDigit() }.width(32)
                        TableColumn("Title") { track in
                            TextField(
                                "Needs title",
                                text: Binding(
                                    get: { dvd.name(of: track) },
                                    set: { dvd.edit("track\(track.source.number).title", value: $0) })
                            )
                            .accessibilityLabel("DVD track \(track.source.number) title")
                        }.width(min: 220, ideal: 350)
                        TableColumn("Artist") { track in
                            TextField(
                                "Artist",
                                text: Binding(
                                    get: { dvd.name(of: track, artist: true) },
                                    set: { dvd.edit("track\(track.source.number).artist", value: $0) })
                            )
                            .accessibilityLabel("DVD track \(track.source.number) artist")
                        }.width(min: 120, ideal: 180)
                        TableColumn("Duration") { track in
                            Text(duration(track.source.durationPTS)).monospacedDigit()
                        }.width(75)
                    }.disabled(dvd.isAccessingDrive)
                } else {
                    ContentUnavailableView(
                        "Choose an audio program", systemImage: "opticaldisc",
                        description: Text("Review stereo, surround and bonus programs separately."))
                }
            } else {
                Spacer()
                if dvd.isInspecting { ProgressView("Inspecting DVD-Audio…").frame(maxWidth: .infinity) }
                Spacer()
            }
            if let error = dvd.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let work = dvd.report?.retainedWork {
                Text(
                    "Partial work retained: \(work.directory)\(work.bytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""). See the rip report for details."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if !dvd.isAccessingDrive, let reason = dvd.cannotRip, dvd.inventory != nil {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if dvd.isAccessingDrive {
                    if let fraction = dvd.fraction {
                        ProgressView(value: fraction).frame(width: 140)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(dvd.status).font(.callout)
                Spacer()
                if let output = dvd.output {
                    Button("Show Output") { NSWorkspace.shared.open(output) }
                }
                if dvd.isAccessingDrive {
                    Button("Stop") { dvd.cancel() }.disabled(dvd.isStopping)
                } else {
                    Button("Rip DVD-Audio…") { dvd.chooseDestination(agreed: model.settings.agreedToPersonalUse) }
                        .buttonStyle(.borderedProminent).disabled(dvd.cannotRip != nil || slot.isDriveBusy)
                }
            }
            DisclosureGroup("Activity") {
                ScrollView {
                    Text(dvd.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading)
                }.frame(height: 100)
            }
            Text(
                "Names are saved for this disc. All source tracks are preserved; verification checks decoded PCM, not an external database."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .task(id: slot.canInspectDVD) {
            if !dvd.hasInspected, slot.canInspectDVD { dvd.inspect() }
        }
    }

    private func importNames() {
        let panel = NSOpenPanel()
        panel.title = "Import DVD Metadata"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { dvd.importMetadata(from: url) }
        }
    }

    private func programLabel(_ program: DVDPresentation) -> String {
        let format = program.format?.description ?? "mixed or unknown format"
        return
            "\(program.id) · \(program.tracks.count) tracks · \(format)\(program.unsupportedReason == nil ? "" : " · unsupported")"
    }

    private func duration(_ ticks: Int64) -> String {
        let seconds = Double(ticks) / 90000
        if seconds < 10 { return String(format: "%.3f s", seconds) }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
