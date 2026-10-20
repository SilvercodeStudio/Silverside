import CDRipKit
import Foundation
import Testing

@testable import CDRipDarwin

struct IoctlTests {
    /// Values printed by a C program that uses the SDK's macros.
    @Test func requestCodesMatchTheSDK() {
        #expect(Ioctl.read == 0xC020_6460)
        #expect(Ioctl.readTOC == 0xC018_6464)
        #expect(Ioctl.readISRC == 0xC010_6461)
        #expect(Ioctl.readMCN == 0xC010_6462)
    }
}

/// The BSD name of the disc for hardware tests, such as disk14 (from `drutil status`).
private let device = ProcessInfo.processInfo.environment["CDRIP_TEST_DEVICE"]

/// The drive's known read offset, if set. Then the test requires a match at this offset.
private let expectedOffset = ProcessInfo.processInfo.environment["CDRIP_TEST_OFFSET"].flatMap { Int($0) }

/// Tests with a real drive and disc. The disc must be in AccurateRip.
@Suite(
    .enabled(if: device != nil, "Set CDRIP_TEST_DEVICE to run hardware tests"),
    .serialized)
struct HardwareTests {
    @Test func readsTOC() throws {
        let drive = try IOKitDrive(bsdName: #require(device))
        let toc = try drive.readTOC()
        print("TOC: \(toc.tracks.count) tracks, lead-out \(toc.leadOutLBA)")
        print("MusicBrainz: \(toc.musicBrainzDiscID)")
        print("AccurateRip: \(toc.accurateRipDiscID.databaseURL)")
        #expect(!toc.audioTracks.isEmpty)
    }

    /// Finds the drive's most likely read offset from the shortest middle track,
    /// then rips the track with that offset and checks that the checksums agree.
    @Test func ripMatchesAccurateRip() async throws {
        let drive = try IOKitDrive(bsdName: #require(device))
        let toc = try drive.readTOC()
        let audio = toc.audioTracks
        try #require(audio.count >= 3, "The disc needs a track that is not first or last")
        let records = try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        if records.isEmpty {
            try Test.cancel("This disc is not in AccurateRip: \(toc.accurateRipDiscID.databaseURL)")
        }

        // The sector 450 search needs at least 451 sectors (6 seconds).
        let middle = audio.dropFirst().dropLast().filter { toc.sectorRange(of: $0).count >= 451 }
        let track = try #require(
            middle.min { toc.sectorRange(of: $0).count < toc.sectorRange(of: $1).count },
            "The disc needs a middle track of at least 6 seconds")
        let index = try #require(audio.firstIndex(of: track))
        let known = Set(records.map { $0.tracks[index].checksum })
        let knownFrame450 = Set(records.map { $0.tracks[index].frame450Checksum })
        let sectors = toc.sectorRange(of: track)
        let positions = (sectors.lowerBound * CDDA.samplesPerSector)..<(sectors.upperBound * CDDA.samplesPerSector)

        let margin = 5 * CDDA.samplesPerSector
        let start = ContinuousClock.now
        let raw = try AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
            .readSamples((positions.lowerBound - margin)..<(positions.upperBound + margin))
        print("Read track \(track.number) (\(sectors.count) sectors) in \(ContinuousClock.now - start)")

        let v1Offsets = AccurateRipOffsetFinder.offsets(
            matching: known, in: raw, trackLength: positions.count, margin: margin)
        let frame450Offsets = AccurateRipOffsetFinder.frame450Offsets(
            matching: knownFrame450, in: raw, trackLength: positions.count, margin: margin)
        print("Offsets that match AccurateRip: v1 \(v1Offsets), sector 450 \(frame450Offsets)")

        // Each pressing of a disc matches at its own offset, and a record can be
        // v1 or v2. A 32-bit match at a wrong offset is very unlikely, so any match
        // counts. One disc cannot show the drive's offset: another pressing can have
        // more submissions, and AccurateRip confidences stop at 200.
        func confidences(_ value: UInt32) -> [Int] {
            records.compactMap { $0.tracks[index].checksum == value ? $0.tracks[index].confidence : nil }
        }
        var matches = [(offset: Int, checksum: AccurateRipChecksum)]()
        for offset in Set(v1Offsets + frame450Offsets).sorted() {
            let window = Array(raw[(margin + offset)..<(margin + offset + positions.count)])
            let checksum = AccurateRipAccumulator.checksum(of: window.span, isFirstTrack: false, isLastTrack: false)
            let v1 = confidences(checksum.v1)
            let v2 = confidences(checksum.v2)
            print(
                String(
                    format: "  offset %+d: v1 %08X confidence %@, v2 %08X confidence %@",
                    offset, checksum.v1, v1.description, checksum.v2, v2.description))
            if !v1.isEmpty || !v2.isEmpty {
                matches.append((offset, checksum))
            }
        }
        let match: (offset: Int, checksum: AccurateRipChecksum)
        if let expectedOffset {
            match = try #require(
                matches.first { $0.offset == expectedOffset }, "No match at the expected offset \(expectedOffset)")
        } else {
            match = try #require(matches.first, "No offset matches AccurateRip")
            print("Set CDRIP_TEST_OFFSET to the drive's offset to check it. Ripping at \(match.offset).")
        }
        let (offset, expected) = match

        let ripped = try AudioReader(drive: drive, toc: toc, readOffset: offset, canOverread: false).readTrack(track)
        #expect(AccurateRipAccumulator.checksum(of: ripped.span, isFirstTrack: false, isLastTrack: false) == expected)
    }
}
