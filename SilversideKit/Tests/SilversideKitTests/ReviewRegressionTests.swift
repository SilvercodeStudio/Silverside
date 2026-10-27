import Foundation
import Testing

@testable import SilversideKit

struct ReviewRegressionTests {
    @Test func alacKeepsPreEmphasisProvenanceTags() throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [1])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .alac).encode(disc, into: library)
        let tags = try MP4Tags.read(files[0]).comments
        #expect(tags.contains { $0.key == "DE_EMPHASIZED" && $0.value == "yes" })
        var keep = DiscEncoder(format: .alac)
        keep.deEmphasizes = false
        let kept = try keep.encode(disc, into: library.appending(path: "kept"))
        #expect(try MP4Tags.read(kept[0]).comments.contains { $0.key == "PRE_EMPHASIS" && $0.value == "yes" })
    }

    struct QRefusingDrive: CDDrive {
        let base: SimulatedDrive
        var rejectsQ = true
        var rejectsC2 = false
        var transferLimit: Int?
        func readTOC() throws -> TOC { base.toc }
        func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8] {
            try base.readAudioSectors(at: lba, count: count)
        }
        func readAudioSectorsWithC2(at lba: Int, count: Int) throws -> (audio: [UInt8], errorFlags: [UInt8]) {
            if rejectsC2 { throw DriveError.readFailed(lba: lba) }
            return try base.readAudioSectorsWithC2(at: lba, count: count)
        }
        func readQSubchannel(at lba: Int, count: Int) throws -> [QSubchannel] {
            if rejectsQ { throw DriveError.readFailed(lba: lba) }
            return try base.readQSubchannel(at: lba, count: count)
        }
        func readAudioSectors(at lba: Int, count: Int, c2: Bool, q: Bool) throws -> SectorRead {
            let bytes = count * (CDDA.bytesPerSector + (c2 ? CDDA.errorFlagBytesPerSector : 0) + (q ? 16 : 0))
            if let transferLimit, bytes > transferLimit { throw DriveError.readFailed(lba: lba) }
            let (audio, flags) =
                c2
                ? try readAudioSectorsWithC2(at: lba, count: count)
                : (try readAudioSectors(at: lba, count: count), [])
            return SectorRead(audio: audio, errorFlags: flags, q: q ? try readQSubchannel(at: lba, count: count) : [])
        }
        func readCDText() throws -> [UInt8]? { nil }
    }

    @Test func refusedQFallsBackToReadableAudio() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        let drive = QRefusingDrive(base: SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440)))
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        let rip = try TrackRipper(reader: reader, records: []).rip(toc.tracks[0])
        #expect(rip.samples == drive.base.samples)
        #expect(rip.unreadableSamples.isEmpty)
    }

    @Test func activeClaimsNeverShareAFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideAudit-\(UUID())")
        let folder = root.appending(path: "rip")
        defer { try? FileManager.default.removeItem(at: root) }
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        let first = try RipFolder.claim(folder, toc: toc)
        let second = try RipFolder.claim(folder, toc: toc)
        defer {
            RipFolder.release(first)
            RipFolder.release(second)
        }
        #expect(first != second)
        #expect(throws: RipFolderError.self) { try RipFolder.claim(folder, toc: toc) }
    }

    @Test(arguments: [false, true])
    func pooledVerificationWritesTheSelectedAudio(missingOriginal: Bool) async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (rip, _, _, root) = try await DiscRipTests().rip { $0.corruptSectors = [1000] }
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appending(path: "good")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        for track in toc.audioTracks {
            let range = toc.sectorRange(of: track)
            try WAVFile.write(
                Array(samples[(range.lowerBound * 588)..<(range.upperBound * 588)]),
                to: good.appending(path: String(format: "Track %02d.wav", track.number)))
        }
        if missingOriginal { try FileManager.default.removeItem(at: rip.folder.appending(path: "Track 02.wav")) }
        var repair = RipRepair(toc: toc, folders: [rip.folder, good])
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let outcome = try await repair.run()
        guard case .verified = outcome.outcome else {
            Issue.record("Expected pooled verification")
            return
        }
        let report = try RipReport.read(from: repair.output.appending(path: "disc.json"))
        let remaining = try WAVFile.read(repair.output.appending(path: "Track 02.wav"))
        #expect(try !RipReport.read(from: rip.folder.appending(path: "disc.json")).isVerified)
        #expect(report.isVerified)
        #expect(remaining == outcome.samples(ofTrack: 1))
    }

    @Test func repairedReportDescribesTheWrittenAudio() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (rip, _, _, root) = try await DiscRipTests().rip { $0.corruptSectors = [1000] }
        defer { try? FileManager.default.removeItem(at: root) }
        var repair = RipRepair(toc: toc, folders: [rip.folder])
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        _ = try await repair.run()
        let report = try RipReport.read(from: repair.output.appending(path: "disc.json"))
        let repaired = try WAVFile.read(repair.output.appending(path: "Track 02.wav"))
        #expect(report.tracks[1].crc32 == CRC32.hex(CRC32.checksum(of: repaired[...])))
        #expect(report.tracks[1].crc32SkipZero == CRC32.hex(CRC32.checksumSkippingZeros(of: repaired[...])))
        let checksum = AccurateRipAccumulator.checksum(of: repaired[...], isFirstTrack: false, isLastTrack: true)
        #expect(report.tracks[1].accurateRipChecksums == [CRC32.hex(checksum.v1), CRC32.hex(checksum.v2)])
        let disc = try RippedDisc(folder: repair.output)
        #expect(try disc.audio(of: disc.tracks[1]) == repaired)
    }

    @Test func damagedCDTextDoesNotReassignTitles() throws {
        var sequence: UInt8 = 0
        var packs = CDTextTests.packs(
            type: 0x80, ["Album1234567", "TrackOne123", "TrackTwo123", "TrackThree"], sequence: &sequence)
        packs[18 + 16] ^= 1
        let text = try #require(CDText(bytes: CDTextTests.disc(packs)))
        #expect(text.titles[1] == nil)
        #expect(text.titles[2] == "TrackTwo123" && text.titles[3] == "TrackThree")
    }

    @Test func cachedReadsDoNotEstablishIndependentAgreement() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        let samples = PreEmphasisTests.sine(440)
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.cacheSectors = 1000
        drive.unstableSectors = [10]
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let rip = try SecureRipper(ripper: TrackRipper(reader: reader, records: [])).rip(toc.tracks[0])
        #expect(rip.status == .suspect)
        #expect(rip.samples != samples)
        #expect(drive.discReads == 3)
    }

    @Test func hiddenTrackUnreadableSectorPreventsAgreement() throws {
        let toc = try TOC(audioTrackStarts: [200], leadOutLBA: 400)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 400 * 588))
        drive.unreadableSectors = [100]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 50))
        #expect(!hidden.readsAgree && !hidden.cacheFlushIncomplete)
        #expect(hidden.unreadableSamples.count == 588)
        #expect(hidden.samples[(100 * 588)..<(101 * 588)].allSatisfy { $0 == 0 })
    }

    @Test func changedWAVCannotInheritVerification() throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        var samples = try WAVFile.read(disc.tracks[0].file)
        samples[100] ^= 1234
        try WAVFile.write(samples, to: disc.tracks[0].file)
        #expect(throws: EncodingError.sourceChanged(disc.tracks[0].file)) {
            try DiscEncoder(format: .flac).encode(disc, into: library)
        }
    }

    @Test func listeningCueClearsPreAfterDeemphasis() throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [1])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var encoder = DiscEncoder(format: .flac)
        encoder.images = folder.deletingLastPathComponent().appending(path: "images")
        let (files, record) = try encoder.encodeWithRecord(try RippedDisc(folder: folder), into: library)
        let album = files[0].deletingLastPathComponent()
        let cue = try FileManager.default.contentsOfDirectory(at: album, includingPropertiesForKeys: nil).first {
            $0.pathExtension == "cue"
        }!
        #expect(record?.deEmphasizedTracks == [1])
        #expect(try !String(contentsOf: cue, encoding: .utf8).contains("FLAGS PRE"))
        let image = URL(filePath: try #require(record?.image))
        #expect(
            try String(contentsOf: image.deletingPathExtension().appendingPathExtension("cue"), encoding: .utf8)
                .contains("FLAGS PRE"))
        _ = try encoder.updateLibrary(reportAt: album.appending(path: "Rip Report.json"), library: library)
        #expect(try !String(contentsOf: cue, encoding: .utf8).contains("FLAGS PRE"))
    }

    @Test func duplicatePlannedPathsFailBeforeWriting() throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var encoder = DiscEncoder(format: .flac)
        encoder.trackTemplate = NameTemplate("same")
        encoder.parallelTracks = 1
        #expect(throws: EncodingError.self) { try encoder.encode(try RippedDisc(folder: folder), into: library) }
        #expect(!FileManager.default.fileExists(atPath: library.path))
    }

    @Test func retagMergePreservesConflictingSourceFiles() throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let files = try DiscEncoder(format: .flac).encode(try RippedDisc(folder: folder), into: library)
        let current = files[0].deletingLastPathComponent()
        let destination = library.appending(path: "Merged")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = try Data(contentsOf: files[0])
        try Data("collision".utf8).write(to: destination.appending(path: files[0].lastPathComponent))
        var encoder = DiscEncoder(format: .flac)
        encoder.folderTemplate = NameTemplate("Merged")
        #expect(throws: EncodingError.self) {
            try encoder.updateLibrary(reportAt: current.appending(path: "Rip Report.json"), library: library)
        }
        #expect(try Data(contentsOf: files[0]) == original)
        #expect(try Data(contentsOf: destination.appending(path: files[0].lastPathComponent)) != original)
    }
    @Test(arguments: [("Song", "song"), ("Café", "Cafe\u{301}"), ("A/B", "A:B")])
    func aliasedTrackNamesCannotOverwriteEachOther(names: (String, String)) throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var disc = try RippedDisc(folder: folder)
        disc.release?.media[0].tracks[0].title = names.0
        disc.release?.media[0].tracks[1].title = names.1
        var encoder = DiscEncoder(format: .flac)
        encoder.trackTemplate = NameTemplate("{title}")
        #expect(throws: EncodingError.self) { try encoder.encode(disc, into: library) }
        #expect(!FileManager.default.fileExists(atPath: library.path))
    }

    @Test func abandonedSameDiscClaimCanResume() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideAudit-\(UUID())")
        let folder = root.appending(path: "rip")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        try Data(toc.ctdbTOCString.utf8).write(to: folder.appending(path: RipFolder.claimFile))
        let claimed = try RipFolder.claim(folder, toc: toc)
        #expect(claimed == folder)
        RipFolder.release(claimed)
        let resumed = try RipFolder.claim(folder, toc: toc)
        #expect(resumed == folder)
        RipFolder.release(resumed)
    }

    /// A drive that cannot read before track 1 reads it twice, not four times: the area is
    /// reported as unreadable, not kept as a silent hidden track.
    @Test func hiddenAreaThatCannotBeReadIsReadTwice() throws {
        let toc = try TOC(audioTrackStarts: [200], leadOutLBA: 400)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 400 * 588))
        drive.unreadableSectors = Set(0..<200)
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 50))
        #expect(!hidden.readsAgree && hidden.unreadableSamples.count == 200 * 588)
        #expect(hidden.reads == 2 && hidden.isUnreadable)
    }

    /// A first pass that reads nothing can be a run of bad reads: the next passes read it.
    @Test func hiddenAreaCanRecoverAfterAFailedFirstPass() throws {
        let toc = try TOC(audioTrackStarts: [10], leadOutLBA: 1000)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 1000 * 588))
        drive.failingReads = Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, 5) })
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 3
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 10))
        #expect(hidden.readsAgree && !hidden.isUnreadable)
        #expect(hidden.samples == Array(drive.samples[..<(10 * 588)]))
    }

    /// One whole sector of audio is a hidden track, though the sector before it is unreadable.
    @Test func readableHiddenAudioIsKept() throws {
        let toc = try TOC(audioTrackStarts: [2], leadOutLBA: 100)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 100 * 588))
        drive.unreadableSectors = [0]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 10))
        #expect(hidden.peak > HiddenTrackRip.silencePeak && !hidden.isUnreadable && !hidden.readsAgree)
    }

    /// A drive that reads nothing before track 1 still reads track 1's first sector, and the
    /// read offset brings in the last samples before track 1 from it. Those few samples are
    /// not a hidden track: the area is unreadable.
    @Test(arguments: [1, 103, 587])
    func offsetFragmentIsNotAHiddenTrack(offset: Int) throws {
        let toc = try TOC(audioTrackStarts: [10], leadOutLBA: 1000)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 1000 * 588))
        drive.readOffset = offset
        drive.unreadableSectors = Set(0..<10)
        var reader = AudioReader(drive: drive, toc: toc, readOffset: offset, canOverread: false)
        reader.unreadableRetries = 0
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 10))
        #expect(hidden.samples.count - hidden.unreadableSamples.count == offset)
        #expect(hidden.peak > HiddenTrackRip.silencePeak)
        #expect(hidden.isUnreadable && hidden.reads == 2)
    }

    /// A drive that refuses C2 but gives the Q subchannel keeps the Q frames.
    @Test func refusedC2KeepsTheQFrames() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 200)
        let base = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 200 * 588))
        base.qControl = [1: 1]
        let drive = QRefusingDrive(base: base, rejectsQ: false, rejectsC2: true)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let read = try reader.read(0..<(200 * 588), withC2: true, withQ: true)
        #expect(read.samples == base.samples && read.q.count == 200 && !read.c2Available)
    }

    /// A rip in a drive that cannot read before track 1 keeps no hidden track, and says so.
    @Test func ripReportsAnUnreadableHiddenAreaWithoutATrack() async throws {
        let (result, events, _, root) = try await DiscRipTests().rip(
            trackSectors: [300, 800, 900], hidesFirstTrack: true,
            prepare: { $0.unreadableSectors = Set(0..<300) })
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.hiddenTrack == nil)
        #expect(result.report.hiddenAreaUnreadableSectors == 300)
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: "Track 00.wav").path))
        #expect(events.contains { if case .hiddenAreaUnreadable(300, 300) = $0 { true } else { false } })
        #expect(result.report.markdown.contains("Before track 1: 300 sectors could not be read"))
    }

    /// A damaged sector that reads on a later try does not cost the track its Q frames or
    /// its C2 flags, once the drive has given them.
    @Test(arguments: [1, 2])
    func damagedSectorKeepsTheQFramesAndC2Flags(failures: Int) throws {
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 2000 * 588))
        drive.qControl = [1: 1]
        drive.failingReads = [300: failures]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 3
        var ripper = TrackRipper(reader: reader, records: [])
        ripper.readsC2 = true
        let rip = try ripper.rip(toc.tracks[0])
        #expect(rip.subchannel?.frames == 1000)
        #expect(rip.subchannel?.hasPreEmphasis == true)
        #expect(rip.c2Samples != nil && rip.unreadableSamples.isEmpty)
    }

    /// A drive that refuses the Q subchannel is asked twice, then reads without it.
    @Test func refusedQStopsAfterTwoRefusals() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 200)
        let drive = QRefusingDrive(
            base: SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 200 * 588)))
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let read = try reader.read(0..<(200 * 588), withC2: true, withQ: true)
        #expect(read.samples == drive.base.samples && read.q.isEmpty && read.c2Available)
    }

    /// A whole track longer than the drive's cache is read from the disc again even when no
    /// flush can be made away from it (one track fills the disc): its reads confirm it.
    @Test func longTrackConfirmsItselfWithoutAFlush() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 3000)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 3000 * 588))
        drive.cacheSectors = 100
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        var secure = SecureRipper(ripper: TrackRipper(reader: reader, records: []))
        secure.cacheFlushSectors = 256
        let rip = try secure.rip(toc.tracks[0])
        #expect(rip.status == .consistent && !rip.cacheFlushIncomplete)
    }

    @Test func hiddenAudioNeedsTwoSuccessfulIndependentReads() throws {
        let toc = try TOC(audioTrackStarts: [200], leadOutLBA: 400)
        let drive = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440, frames: 400 * 588))
        drive.failingReads = [100: 2]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 50))
        #expect(hidden.readsAgree && hidden.reads == 3)
        #expect(hidden.unreadableSamples.isEmpty)
        #expect(hidden.samples == Array(drive.samples[..<(200 * 588)]))
    }

    @Test func failedFlushCommandsDoNotCountTowardsEviction() throws {
        let (toc, samples) = try makeDisc(trackSectors: [500, 500, 1000])
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.unreadableSectors = Set(0..<500).union(1000..<2000)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        #expect(try !reader.flushCache(awayFrom: 500..<1000, count: 100))
    }

    @Test(arguments: [AudioFormat.aiff, .wav])
    func chunkContainersKeepEmphasisProvenance(format: AudioFormat) throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [1])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        var encoder = DiscEncoder(format: format)
        encoder.replayGain = false
        let processed = try encoder.encode(disc, into: library)
        #expect(try Data(contentsOf: processed[0]).range(of: Data("DE_EMPHASIZED".utf8)) != nil)
        encoder.deEmphasizes = false
        let kept = try encoder.encode(disc, into: library.appending(path: "kept"))
        #expect(try Data(contentsOf: kept[0]).range(of: Data("PRE_EMPHASIS".utf8)) != nil)
        #expect(try AudioEncoder.decode(kept[0]) == disc.audio(of: disc.tracks[0]))
    }

    @Test func mp3ID3KeepsEmphasisProvenance() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SilversideAudit-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        for key in ["PRE_EMPHASIS", "DE_EMPHASIZED"] {
            try ID3Tags.tag([(key, "yes")], cover: nil).write(to: file)
            #expect(try ID3Tags.readTextFrames(file)["TXXX"] == key + "\0yes")
        }
    }

    @Test func changedWAVCannotBeRecheckedAsStillVerified() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (rip, _, _, root) = try await DiscRipTests().rip(web: DiscRipTests.web(toc: toc, samples: samples))
        defer { try? FileManager.default.removeItem(at: root) }
        let file = rip.folder.appending(path: "Track 01.wav")
        var audio = try WAVFile.read(file)
        audio[100] ^= 1
        try WAVFile.write(audio, to: file)
        var check = RipCheck(reportAt: rip.folder.appending(path: "disc.json"))
        check.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(
            in: root.appending(path: "check-cache"))
        await #expect(throws: EncodingError.sourceChanged(file)) { try await check.run() }
    }

    @Test func refusedC2DoesNotTurnGoodAudioIntoUnreadableSectors() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        let base = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440))
        let drive = QRefusingDrive(base: base, rejectsQ: false, rejectsC2: true)
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        var ripper = TrackRipper(reader: reader, records: [])
        ripper.readsC2 = true
        let rip = try ripper.rip(toc.tracks[0])
        #expect(rip.samples == base.samples && rip.unreadableSamples.isEmpty)
        #expect(rip.c2Samples == nil)
    }

    @Test func optionalPayloadFitsWithinTheBridgeTransferLimit() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        let base = SimulatedDrive(toc: toc, samples: PreEmphasisTests.sine(440))
        let drive = QRefusingDrive(base: base, rejectsQ: false, transferLimit: 65_536)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let read = try reader.read(0..<(75 * 588), withC2: true, withQ: true)
        #expect(read.samples == base.samples && read.unreadable.isEmpty)
        #expect(read.c2Available && read.q.count == 75)
    }

    @Test func damagedContinuationResumesAtTheNextTitle() throws {
        var sequence: UInt8 = 0
        var packs = CDTextTests.packs(
            type: 0x80, ["Album", "abcdefghijklmnopqrstuvwx", "Three", "Four"], sequence: &sequence)
        packs[18 + 16] ^= 1
        let text = try #require(CDText(bytes: CDTextTests.disc(packs)))
        #expect(text.titles[0] == "Album" && text.titles[1] == nil)
        #expect(text.titles[2] == "Three" && text.titles[3] == "Four")
    }

    @Test func doubleByteTerminatorMayCrossAPackBoundary() throws {
        var sequence: UInt8 = 0
        let packs = CDTextTests.packs(
            type: 0x80, ["12345678901", "Next", "Last"], block: 0, msJIS: true, sequence: &sequence)
        let text = try #require(CDText(bytes: CDTextTests.disc(packs)))
        #expect(text.titles == [0: "12345678901", 1: "Next", 2: "Last"])
    }

    @Test func symlinkAliasesCannotClaimTheSameFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideAudit-\(UUID())")
        let folder = root.appending(path: "real/rip")
        let alias = root.appending(path: "links/alias")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 75)
        let first = try RipFolder.claim(folder, toc: toc)
        let second = try RipFolder.claim(alias, toc: toc)
        defer {
            RipFolder.release(first)
            RipFolder.release(second)
        }
        #expect(first.resolvingSymlinksInPath() != second.resolvingSymlinksInPath())
    }

    @Test func albumMergeDeduplicatesOnlyIdenticalFilesAndMergesArtwork() throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let files = try DiscEncoder(format: .flac).encode(try RippedDisc(folder: folder), into: library)
        let current = files[0].deletingLastPathComponent()
        let destination = library.appending(path: "Merged")
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Artwork"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: current.appending(path: "Artwork"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: files[0], to: destination.appending(path: files[0].lastPathComponent))
        for location in [current, destination] {
            try Data("same".utf8).write(to: location.appending(path: "Artwork/shared.txt"))
        }
        try Data("mine".utf8).write(to: current.appending(path: "Artwork/source.txt"))
        try Data("theirs".utf8).write(to: destination.appending(path: "Artwork/destination.txt"))
        var encoder = DiscEncoder(format: .flac)
        encoder.folderTemplate = NameTemplate("Merged")
        let update = try encoder.updateLibrary(reportAt: current.appending(path: "Rip Report.json"), library: library)
        #expect(update.files.count == 3 && !FileManager.default.fileExists(atPath: current.path))
        for file in update.files { #expect(try !AudioEncoder.decode(file).isEmpty) }
        #expect(try Data(contentsOf: destination.appending(path: "Artwork/source.txt")) == Data("mine".utf8))
        #expect(try Data(contentsOf: destination.appending(path: "Artwork/destination.txt")) == Data("theirs".utf8))
    }

}
