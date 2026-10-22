import Foundation
import Testing

@testable import SilversideKit

struct DriveOffsetListTests {
    /// A 69-byte record: offset, 32-byte name, submission count, and zeros.
    func record(_ offset: Int16, _ name: String, _ submissions: UInt32) -> [UInt8] {
        let nameBytes = Array(name.utf8) + [UInt8](repeating: 0, count: 32 - name.utf8.count)
        let offsetBytes = withUnsafeBytes(of: offset.littleEndian, Array.init)
        let countBytes = withUnsafeBytes(of: submissions.littleEndian, Array.init)
        return offsetBytes + nameBytes + countBytes + [UInt8](repeating: 0, count: 31)
    }

    @Test func parsesTheFirstRealRecord() throws {
        // The first record of DriveOffsets.bin, fetched 2026-10-19.
        let bytes =
            hexBytes("5b002d20313658313220445644204455414c") + [UInt8](repeating: 0, count: 16) + [10]
            + [UInt8](repeating: 0, count: 34)
        let list = try DriveOffsetList(bytes: bytes)
        #expect(list.entries == [.init(vendor: "", product: "16X12 DVD DUAL", offset: 91, submissions: 10)])
    }

    @Test func findsDrivesByProductAndVendorAlias() throws {
        let list = try DriveOffsetList(
            bytes: record(6, "LG Electronics - BD-RE BU50N", 51) + record(6, "hp HLDS - BDRE BU50N", 14)
                + record(102, "Generic - BD-MLT UJ260AF", 900) + record(103, "Panasonic - BD-MLT UJ260AF", 648)
                + record(-24, "GoldStar - CD-ROM CRD-8322B", 5))
        #expect(list.entry(vendor: "HL-DT-ST", product: "BD-RE BU50N")?.offset == 6)
        // The alias wins over a vendor that is not the drive's, even with more submissions.
        #expect(list.entry(vendor: "MATSHITA", product: "BD-MLT UJ260AF")?.offset == 103)
        #expect(list.entry(vendor: "GoldStar", product: "CD-ROM CRD-8322B")?.offset == -24)
        #expect(list.entry(vendor: "ASUS", product: "BW-16D1HT") == nil)
    }

    @Test func rejectsATruncatedFile() {
        #expect(throws: DriveOffsetListError.malformed) { try DriveOffsetList(bytes: [UInt8](repeating: 0, count: 68)) }
    }
}

struct DriveProfileTests {
    @Test func confirmsTheOffsetThatTheMostDiscsShare() {
        var profile = DriveProfile(vendor: "MATSHITA", product: "BD-MLT UJ260AF", revision: "1.00")
        profile.record(disc: "a", offsets: [103, 298, 752])
        #expect(profile.confirmedOffset == nil)
        profile.record(disc: "b", offsets: [103])
        profile.record(disc: "c", offsets: [124, 773, 103])
        #expect(profile.confirmedOffset == 103)
    }

    @Test func doesNotConfirmATie() {
        var profile = DriveProfile(vendor: "V", product: "P", revision: "1")
        profile.record(disc: "a", offsets: [1, 2])
        profile.record(disc: "b", offsets: [2, 1])
        #expect(profile.confirmedOffset == nil)
    }

    @Test func aNewRipOfADiscReplacesTheOld() {
        var profile = DriveProfile(vendor: "V", product: "P", revision: "1")
        profile.record(disc: "a", offsets: [5])
        profile.record(disc: "a", offsets: [5])
        #expect(profile.observations.count == 1 && profile.confirmedOffset == nil)
    }

    @Test func prefersManualThenConfirmedThenListed() {
        var profile = DriveProfile(vendor: "V", product: "P", revision: "1")
        #expect(profile.offset == nil)
        profile.listedOffset = 6
        #expect(profile.offset?.value == 6 && profile.offset?.source == .accurateRipList)
        profile.record(disc: "a", offsets: [7])
        profile.record(disc: "b", offsets: [7])
        #expect(profile.offset?.value == 7 && profile.offset?.source == .confirmed)
        profile.manualOffset = 8
        #expect(profile.offset?.value == 8 && profile.offset?.source == .manual)
    }

    /// Two rips in different drives use the store at once. Neither may lose the other's profile.
    @Test func saveKeepsProfilesThatAnotherStoreSaved() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())/DriveProfiles.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var first = try DriveProfileStore(url: url)
        var second = try DriveProfileStore(url: url)
        var lg = first.profile(vendor: "HL-DT-ST", product: "BD-RE BU50N", revision: "CC03")
        lg.listedOffset = 6
        try first.save(lg)
        var asus = second.profile(vendor: "ASUS", product: "BW-16D1HT", revision: "3.10")
        asus.listedOffset = 6
        try second.save(asus)
        #expect(try DriveProfileStore(url: url).profiles.count == 2)
    }

    @Test func storeSavesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())/DriveProfiles.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try DriveProfileStore(url: url)
        var profile = store.profile(vendor: "HL-DT-ST", product: "BD-RE BU50N", revision: "CC03")
        profile.listedOffset = 6
        profile.record(disc: "dBAR-004-0007b697-001e0899-3809ca04", offsets: [-1070, -943, 6])
        try store.save(profile)
        let loaded = try DriveProfileStore(url: url).profile(
            vendor: "HL-DT-ST", product: "BD-RE BU50N", revision: "CC03")
        #expect(loaded.listedOffset == 6)
        #expect(loaded.observations.map(\.offsets) == [[-1070, -943, 6]])
    }
}

struct TrackRipperTests {
    static let driveOffset = 667

    /// A disc whose tracks are long enough for the sector 450 checksum, and an
    /// AccurateRip record made from its true samples: v2 checksums, as recent rippers submit.
    func disc() throws -> (toc: TOC, samples: [UInt32], record: AccurateRipRecord) {
        let (toc, samples) = try makeDisc(trackSectors: [460, 470, 460])
        let tracks = toc.tracks.enumerated().map { index, track in
            let sectors = toc.sectorRange(of: track)
            let start = sectors.lowerBound * CDDA.samplesPerSector
            let trackSamples = Array(samples[start..<(sectors.upperBound * CDDA.samplesPerSector)])
            let checksum = AccurateRipAccumulator.checksum(
                of: trackSamples[...], isFirstTrack: index == 0, isLastTrack: index == toc.tracks.count - 1)
            let sector450 = Array(trackSamples[(450 * 588)..<(451 * 588)])
            let frame450 = AccurateRipAccumulator.checksum(of: sector450[...], isFirstTrack: false, isLastTrack: false)
            return AccurateRipRecord.Track(confidence: 4, checksum: checksum.v2, frame450Checksum: frame450.v1)
        }
        return (toc, samples, AccurateRipRecord(discID: toc.accurateRipDiscID, tracks: tracks))
    }

    func ripper(readOffset: Int, records: [AccurateRipRecord], toc: TOC, samples: [UInt32]) -> TrackRipper {
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: Self.driveOffset)
        return TrackRipper(
            reader: AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false), records: records)
    }

    @Test func ripsAccuratelyAtTheDriveOffset() throws {
        let (toc, samples, record) = try disc()
        let ripper = ripper(readOffset: Self.driveOffset, records: [record], toc: toc, samples: samples)
        for track in toc.tracks {
            let rip = try ripper.rip(track)
            #expect(rip.verification == .accurate(v1Confidence: 0, v2Confidence: 4))
            #expect(rip.matchingOffsets == [Self.driveOffset])
        }
        // The middle track has no edge, so its samples are exactly the disc's.
        let middle = toc.sectorRange(of: toc.tracks[1])
        let rip = try ripper.rip(toc.tracks[1])
        #expect(rip.samples[...] == samples[(middle.lowerBound * 588)..<(middle.upperBound * 588)])
    }

    @Test func findsTheDriveOffsetFromAWrongOne() throws {
        let (toc, samples, record) = try disc()
        let ripper = ripper(readOffset: 0, records: [record], toc: toc, samples: samples)
        for track in toc.tracks {
            let rip = try ripper.rip(track)
            #expect(rip.verification == .notAccurate)
            #expect(rip.matchingOffsets == [Self.driveOffset])
        }
    }

    @Test func doesNotCheckWithoutRecords() throws {
        let (toc, samples, _) = try disc()
        let rip = try ripper(readOffset: Self.driveOffset, records: [], toc: toc, samples: samples).rip(toc.tracks[0])
        #expect(rip.verification == .notChecked && rip.matchingOffsets.isEmpty)
    }
}

struct WAVFileTests {
    @Test func readsWhatItWrites() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [UInt32] = [0x0002_0001, 0xFFFF_8000, 0]
        try WAVFile.write(samples, to: url)
        #expect(try WAVFile.read(url) == samples)
    }

    @Test func writesAPCMHeader() {
        let data = [UInt8](WAVFile.data(for: [0x0002_0001]))
        #expect(data.count == 48)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8) && Array(data[8..<16]) == Array("WAVEfmt ".utf8))
        #expect(data[4] == 40 && data[22] == 2 && data[34] == 16 && data[40] == 4)
        #expect(Array(data[44...]) == [0x01, 0x00, 0x02, 0x00])
    }

    /// Other chunks before the audio, of odd sizes with a pad byte, are stepped over.
    @Test func stepsOverOtherChunks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [UInt32] = [0x0002_0001, 0xFFFF_8000, 0]
        var data = [UInt8](WAVFile.data(for: samples))
        // A LIST chunk of 5 bytes (so a pad byte follows) between "WAVE" and "fmt ".
        let list: [UInt8] = Array("LIST".utf8) + [5, 0, 0, 0] + Array("INFOa".utf8) + [0]
        data.insert(contentsOf: list, at: 12)
        let size = UInt32(data.count - 8)
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: size.littleEndian, Array.init))
        try Data(data).write(to: url)
        #expect(try WAVFile.read(url) == samples)
    }

    /// Some programs write 16-bit stereo in the extensible form: format tag 0xFFFE, and the
    /// PCM format in the subformat.
    @Test func readsTheExtensibleForm() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [UInt32] = [0x0002_0001, 0xFFFF_8000, 0]
        var data = Data()
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(4 + 8 + 40 + 8 + samples.count * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(40)
        append16(0xFFFE)
        append16(2)
        append32(44100)
        append32(44100 * 4)
        append16(4)
        append16(16)
        append16(22)  // the extension's size
        append16(16)  // valid bits
        append32(3)  // channel mask
        // The PCM subformat GUID.
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71])
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(samples.count * 4))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
        #expect(try WAVFile.read(url) == samples)
        // Another subformat (floating point) is not CD audio.
        data[20 + 24] = 3
        try data.write(to: url)
        #expect(throws: WAVFileError.self) { try WAVFile.read(url) }
    }
}

struct RipPoolTests {
    /// Track files that are there but cannot be used are reported, not dropped in silence.
    @Test func reportsTrackFilesItCannotUse() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let toc = try TOC(audioTrackStarts: [0, 10], leadOutLBA: 20)
        let folders = ["good", "short", "text", "empty"].map { root.appending(path: $0, directoryHint: .isDirectory) }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try WAVFile.write([UInt32](repeating: 7, count: 10 * 588), to: folders[0].appending(path: "Track 01.wav"))
        try WAVFile.write([UInt32](repeating: 7, count: 100), to: folders[1].appending(path: "Track 01.wav"))
        try Data("hello".utf8).write(to: folders[2].appending(path: "Track 01.wav"))
        let pooled = RipPool.versions(of: toc.tracks[0], toc: toc, in: folders)
        #expect(pooled.versions.count == 1)
        #expect(pooled.skipped.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["short", "text"])
        #expect(pooled.skipped[0].reason == "it has 100 samples, and the track 5880")
        #expect(pooled.skipped[1].reason.contains("not a WAV file"))
    }
}
