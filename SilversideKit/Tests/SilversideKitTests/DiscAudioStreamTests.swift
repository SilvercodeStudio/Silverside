import Testing

@testable import SilversideKit

struct DiscAudioStreamTests {
    /// The pieces, a second each and the last one shorter, add up to the track as a rip reads it.
    @Test func readsATrackInPieces() throws {
        let (toc, samples) = try makeDisc(trackSectors: [200, 190])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        var stream = DiscAudioStream(reader: reader, track: toc.audioTracks[1])
        var pieces = [[UInt32]]()
        while let piece = try stream.next() { pieces.append(piece) }
        #expect(pieces.map(\.count) == [75, 75, 40].map { $0 * CDDA.samplesPerSector })
        #expect(try pieces.flatMap { $0 } == reader.readTrack(toc.audioTracks[1]))
        #expect(stream.isAtEnd && stream.position == 190)
    }

    /// A seek continues from the sector asked for, and a sector that cannot be read is silence.
    @Test func seeksAndPlaysThroughADamagedSector() throws {
        let (toc, samples) = try makeDisc(trackSectors: [200])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 0)
        drive.unreadableSectors = [150]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 0
        var stream = DiscAudioStream(reader: reader, track: toc.audioTracks[0], startingAtSector: 120)
        let piece = try #require(try stream.next())
        #expect(piece.count == 75 * CDDA.samplesPerSector && stream.position == 195)
        let damaged = piece[(30 * CDDA.samplesPerSector)..<(31 * CDDA.samplesPerSector)]
        #expect(damaged.allSatisfy { $0 == 0 })
        #expect(Array(piece[0..<CDDA.samplesPerSector]) == Array(samples[(120 * 588)..<(121 * 588)]))
        stream.seek(toSector: 500)
        #expect(stream.isAtEnd)
        #expect(try stream.next() == nil)
    }
}
