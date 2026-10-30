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

    /// A DTS decode of an earlier rip, with ffmpeg: as an album of its own beside the album,
    /// its title ending in `suffix` (" (DTS 5.1)"), in `format`; or in place of the album's files.
    struct DTSDecode {
        var rip: RecentRip
        var beside: Bool
        var format: AudioFormat
        var suffix = " (DTS 5.1)"
    }

    /// Change Release: another release for an earlier rip, with its cover if it has one.
    struct ReleaseChange {
        var rip: RecentRip
        var release: MusicBrainzRelease
        var cover: CoverImage?
    }

    let id = UUID()
    let title: String
    /// The rips to encode, and the rips whose files to bring up to date.
    let encode: [RecentRip]
    let update: [RecentRip]
    let hdcd: HDCDDecode?
    let dts: DTSDecode?
    let change: ReleaseChange?
    /// The changed rip's report, where it is after the change (an album folder's report moves
    /// when its name or folder changes).
    private(set) var changedReport: (from: URL, to: URL)?
    private(set) var phase = Phase.running
    private(set) var log: [String] = []
    private(set) var encodedDiscs = 0
    private(set) var updatedDiscs = 0
    private(set) var decodedDiscs = 0
    private(set) var problems = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let stopToken = StopToken()

    init(
        title: String, encode: [RecentRip], update: [RecentRip], hdcd: HDCDDecode? = nil, dts: DTSDecode? = nil,
        change: ReleaseChange? = nil
    ) {
        self.title = title
        self.encode = encode
        self.update = update
        self.hdcd = hdcd
        self.dts = dts
        self.change = change
    }

    var isRunning: Bool { phase == .running }

    var headline: String {
        switch phase {
        case .running:
            if change != nil { return "Changing the release…" }
            if dts != nil { return "Decoding DTS…" }
            return hdcd != nil ? "Decoding HDCD…" : encode.isEmpty ? "Updating the library…" : "Encoding…"
        case .stopped: return "Stopped after the disc under way."
        case .failed(let message): return "Failed: \(message)"
        case .finished:
            var parts = [String]()
            if change != nil, changedReport != nil { parts.append("Release changed") }
            if !encode.isEmpty { parts.append("\(Format.count(encodedDiscs, "disc")) encoded") }
            if !update.isEmpty { parts.append("\(Format.count(updatedDiscs, "disc")) brought up to date") }
            if hdcd != nil || dts != nil { parts.append("\(Format.count(decodedDiscs, "disc")) decoded") }
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
        let (encode, update, hdcd, dts, change) = (self.encode, self.update, self.hdcd, self.dts, self.change)
        task = Task.detached {
            @Sendable func onMain(_ body: @escaping @MainActor () -> Void) {
                DispatchQueue.main.async { MainActor.assumeIsolated(body) }
            }
            let library = settings.libraryURL
            // The other discs are brought up to date only after the change, for their album gain.
            if let change {
                let rip = change.rip
                do {
                    var encoder = DiscEncoder(settings: settings)
                    encoder.log = { line in onMain { run.add("  \(line)") } }
                    let result = try encoder.changeRelease(
                        reportAt: rip.file, to: change.release, cover: change.cover, library: library)
                    onMain {
                        run.changedReport = (rip.file, result.report)
                        run.add(
                            "\(rip.title): now \(change.release.artist) – \(change.release.title)"
                                + (result.albumFolder == nil
                                    ? "; not encoded yet, so the files get the names when it is."
                                    : "; wrote the tags of \(Format.count(result.files.count, "file"))"
                                        + (result.renamed > 0 ? ", renamed \(result.renamed)." : ".")))
                    }
                } catch {
                    onMain {
                        run.problems += 1
                        run.add("\(rip.title): the release was not changed: \(error)")
                        run.end(.failed("\(error)"))
                        onFinish()
                    }
                    return
                }
            }
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
                    // A DTS-CD as the setting says; asking is for a rip, so here the stream is kept.
                    let encoded = try encoder.encodeWithRecord(
                        disc, into: library, dts: settings.dts == .ask ? .keep : settings.dts)
                    let (files, record) = (encoded.files, encoded.encoding)
                    try record?.save(inReportAt: rip.folder.appending(path: "disc.json"))
                    // Music plays a DTS stream as static, so it gets the decode, if there is one.
                    let (musicFiles, musicFormat) = encoded.musicFiles
                    if settings.addToMusic, MusicApp.reads(musicFormat ?? settings.format), !musicFiles.isEmpty {
                        do {
                            let added = try MusicApp.add(musicFiles)
                            onMain { run.add("\(rip.title): added \(Format.count(added, "track")) to Music.") }
                        } catch {
                            onMain { run.add("\(rip.title): not added to Music: \(error)") }
                        }
                    }
                    let deletes =
                        !settings.keepRipAfterEncoding
                        && files.count + (record?.silentTracksLeftOut?.count ?? 0) == disc.tracks.count
                        && disc.isFinished
                    let deleted =
                        try deletes && disc.deleteRipFiles(albumFolder: record.map { URL(filePath: $0.folder) })
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
            if let dts, !stop.isStopped {
                let rip = dts.rip
                do {
                    // The rip's WAV files when it still has them, else the album's lossless files.
                    let disc =
                        rip.hasAudio ? try RippedDisc(folder: rip.folder) : try RippedDisc(albumReportAt: rip.file)
                    let format = dts.beside ? dts.format : rip.report.encoding?.format ?? dts.format
                    var encoder = DiscEncoder(settings: settings, format: format)
                    encoder.decodesDTS = true
                    if dts.beside { encoder.albumSuffix = dts.suffix } else { encoder.overwrites = true }
                    encoder.log = { line in onMain { run.add("  \(line)") } }
                    onMain {
                        run.add(
                            "\(rip.title): decoding DTS as \(format.rawValue.uppercased()), "
                                + (dts.beside ? "beside the album…" : "in place of the album's files…"))
                    }
                    let (files, record) = try encoder.encodeWithRecord(disc, into: library)
                    // In place, the rip's own report follows its files; a copy beside it is not the rip's.
                    if !dts.beside, rip.hasAudio { try record?.save(inReportAt: rip.file) }
                    onMain {
                        run.decodedDiscs += 1
                        run.add(
                            "\(rip.title): wrote \(Format.count(files.count, "file")) in \(record?.dtsDecoded ?? "surround"),"
                                + " tagged DTS=decoded"
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
