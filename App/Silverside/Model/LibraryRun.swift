import Foundation
import Observation
import SilversideKit

/// Work on earlier rips in the library, one disc after another: encoding the discs of a set
/// that are not in the library yet, and bringing encoded discs up to date with the set's
/// names and cover. The engine's lines become a log, and the outcome a headline.
@Observable
final class LibraryRun: Identifiable {
    enum Phase: Equatable {
        case running
        case finished
        case stopped
        case failed(String)
    }

    /// An HDCD decode of an earlier rip: as an album of its own beside the album, its title
    /// ending in `suffix` (" (HDCD)"), in `format`; or in place of the album's files, in their format.
    struct HDCDDecode {
        var rip: RecentRip
        var beside: Bool
        var format: AudioFormat
        var suffix = " (HDCD)"
    }

    let id = UUID()
    let title: String
    /// The rips to encode, and the rips whose files to bring up to date.
    let encode: [RecentRip]
    let update: [RecentRip]
    let hdcd: HDCDDecode?
    private(set) var phase = Phase.running
    private(set) var log: [String] = []
    private(set) var encodedDiscs = 0
    private(set) var updatedDiscs = 0
    private(set) var decodedDiscs = 0
    private(set) var problems = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let stopToken = StopToken()

    init(title: String, encode: [RecentRip], update: [RecentRip], hdcd: HDCDDecode? = nil) {
        self.title = title
        self.encode = encode
        self.update = update
        self.hdcd = hdcd
    }

    var isRunning: Bool { phase == .running }

    var headline: String {
        switch phase {
        case .running:
            return hdcd != nil ? "Decoding HDCD…" : encode.isEmpty ? "Updating the library…" : "Encoding…"
        case .stopped: return "Stopped after the disc under way."
        case .failed(let message): return "Failed: \(message)"
        case .finished:
            var parts = [String]()
            if !encode.isEmpty { parts.append("\(Format.count(encodedDiscs, "disc")) encoded") }
            if !update.isEmpty { parts.append("\(Format.count(updatedDiscs, "disc")) brought up to date") }
            if hdcd != nil { parts.append("\(Format.count(decodedDiscs, "disc")) decoded") }
            if problems > 0 { parts.append("\(Format.count(problems, "problem"))") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Starts the work on a thread of its own. `cover`, if given, becomes every disc's cover;
    /// `discCovers` sets or removes a disc's own (a box set's sleeve), by its report file.
    func start(
        settings: Settings, cover: CoverImage?, discCovers: [URL: DiscCoverChange] = [:],
        onFinish: @escaping @MainActor () -> Void
    ) {
        let run = self
        let stop = self.stopToken
        let (encode, update, hdcd) = (self.encode, self.update, self.hdcd)
        task = Task.detached {
            @Sendable func onMain(_ body: @escaping @MainActor () -> Void) {
                DispatchQueue.main.async { MainActor.assumeIsolated(body) }
            }
            let library = settings.libraryURL
            // Every disc first takes the set's current names and the cover; an encoded one has
            // its files written again, a rip that is not encoded yet keeps them in its disc.json.
            for rip in update + encode where !stop.isStopped {
                do {
                    var encoder = DiscEncoder(settings: settings)
                    encoder.log = { line in onMain { run.add("  \(line)") } }
                    let result = try encoder.updateLibrary(
                        reportAt: rip.file, cover: cover, discCover: discCovers[rip.file] ?? .keep, library: library)
                    if update.contains(where: { $0.file == rip.file }) {
                        onMain {
                            run.updatedDiscs += 1
                            run.add(
                                "\(rip.title): wrote the tags of \(Format.count(result.files.count, "file"))"
                                    + (result.renamed > 0 ? ", renamed \(result.renamed)" : "") + ".")
                        }
                    }
                } catch {
                    onMain {
                        run.problems += 1
                        run.add("\(rip.title): \(error)")
                    }
                }
            }
            for rip in encode where !stop.isStopped {
                do {
                    let disc = try RippedDisc(folder: rip.folder)
                    var encoder = DiscEncoder(settings: settings)
                    encoder.log = { line in onMain { run.add("  \(line)") } }
                    onMain { run.add("\(rip.title): encoding as \(settings.format.rawValue.uppercased())…") }
                    let (files, record) = try encoder.encodeWithRecord(disc, into: library)
                    try record?.save(inReportAt: rip.folder.appending(path: "disc.json"))
                    if settings.addToMusic, MusicApp.reads(settings.format), !files.isEmpty {
                        do {
                            let added = try MusicApp.add(files)
                            onMain { run.add("\(rip.title): added \(Format.count(added, "track")) to Music.") }
                        } catch {
                            onMain { run.add("\(rip.title): not added to Music: \(error)") }
                        }
                    }
                    let deletes =
                        !settings.keepRipAfterEncoding && files.count == disc.tracks.count
                        && disc.tracks.allSatisfy(\.isVerified)
                    if deletes { try disc.deleteRipFiles() }
                    let deleted = deletes
                    onMain {
                        run.encodedDiscs += 1
                        run.add(
                            "\(rip.title): encoded \(Format.count(files.count, "track"))"
                                + (deleted ? "; the rip's WAV files were deleted." : "."))
                    }
                } catch EncodingError.exists(let file) {
                    onMain {
                        run.problems += 1
                        run.add(
                            "\(rip.title): the library already has \(file.lastPathComponent). Use Update the Library.")
                    }
                } catch {
                    onMain {
                        run.problems += 1
                        run.add("\(rip.title): \(error)")
                    }
                }
            }
            if let hdcd, !stop.isStopped {
                let rip = hdcd.rip
                do {
                    // The rip's WAV files when it still has them, else the album's lossless files.
                    let disc =
                        rip.hasAudio ? try RippedDisc(folder: rip.folder) : try RippedDisc(albumReportAt: rip.file)
                    let format = hdcd.beside ? hdcd.format : rip.report.encoding?.format ?? hdcd.format
                    var encoder = DiscEncoder(settings: settings, format: format)
                    encoder.decodesHDCD = true
                    if hdcd.beside { encoder.albumSuffix = hdcd.suffix } else { encoder.overwrites = true }
                    encoder.log = { line in onMain { run.add("  \(line)") } }
                    onMain {
                        run.add(
                            "\(rip.title): decoding HDCD as \(format.rawValue.uppercased()), "
                                + (hdcd.beside ? "beside the album…" : "in place of the album's files…"))
                    }
                    let (files, record) = try encoder.encodeWithRecord(disc, into: library)
                    // In place, the rip's own report follows its files; a copy beside it is not the rip's.
                    if !hdcd.beside, rip.hasAudio { try record?.save(inReportAt: rip.file) }
                    onMain {
                        run.decodedDiscs += 1
                        run.add(
                            "\(rip.title): wrote \(Format.count(files.count, "file")), tagged HDCD=decoded"
                                + (files.first.map {
                                    ", in \(($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)"
                                } ?? "")
                                + ".")
                    }
                } catch {
                    onMain {
                        run.problems += 1
                        run.add("\(rip.title): \(error)")
                    }
                }
            }
            onMain {
                run.end(stop.isStopped ? .stopped : .finished)
                onFinish()
            }
        }
    }

    /// Stops after the disc under way.
    func stop() {
        stopToken.stop()
        add("Stopping after the disc under way…")
    }

    private func end(_ phase: Phase) {
        self.phase = phase
        add(headline)
    }

    private func add(_ line: String) {
        log.append(line)
    }
}
