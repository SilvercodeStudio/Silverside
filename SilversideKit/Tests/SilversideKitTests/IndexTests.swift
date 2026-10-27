import Foundation
import Testing

@testable import SilversideKit

/// Index points after 01, unknown pregaps, and the padded edges of the disc's audio.
struct IndexTests {
    /// The Q positions of every sector of `range`, as a rip's first read gives them.
    func positions(_ drive: SimulatedDrive, _ range: Range<Int>) throws -> [QSubchannel.Position] {
        try drive.readQSubchannel(at: range.lowerBound, count: range.count).compactMap(\.position)
    }

    @Test func findsIndexPointsFromTheRipsFrames() throws {
        let toc = try TOC(audioTrackStarts: [0, 800], leadOutLBA: 1700)
        let drive = SimulatedDrive(toc: toc, samples: [UInt32](repeating: 0, count: 1700 * 588))
        drive.indexes = [2: [1100, 1450]]
        let found = PregapFinder.indexes(
            of: toc.tracks[1], in: toc, positions: try positions(drive, 790..<1700), drive: drive)
        #expect(found == [.init(number: 2, sectors: 300), .init(number: 3, sectors: 650)])
        #expect(
            PregapFinder.indexes(of: toc.tracks[0], in: toc, positions: try positions(drive, 0..<800), drive: drive)
                == [])
    }

    /// Damaged frames at a change leave it unknown in the rip's frames: the drive's Q
    /// subchannel is read again there, and the change is exact.
    @Test func readsTheQSubchannelAgainWhereFramesAreMissing() throws {
        let toc = try TOC(audioTrackStarts: [0, 800], leadOutLBA: 1700)
        let drive = SimulatedDrive(toc: toc, samples: [UInt32](repeating: 0, count: 1700 * 588))
        drive.indexes = [2: [1100]]
        let gapped = try positions(drive, 800..<1700).filter { !(1095..<1105).contains($0.lba) }
        #expect(
            PregapFinder.indexes(of: toc.tracks[1], in: toc, positions: gapped, drive: drive) == [
                .init(number: 2, sectors: 300)
            ])
    }

    /// A frame whose CRC passes by chance can name an index that is not there. One frame does not make an index.
    @Test func leavesOutAnIndexThatOneFrameNames() throws {
        let toc = try TOC(audioTrackStarts: [0, 800], leadOutLBA: 1700)
        let drive = SimulatedDrive(toc: toc, samples: [UInt32](repeating: 0, count: 1700 * 588))
        var frames = try positions(drive, 800..<1700)
        frames[200].index = 5
        #expect(PregapFinder.indexes(of: toc.tracks[1], in: toc, positions: frames, drive: drive) == [])
    }

    @Test func cueSheetsHaveTheIndexPoints() {
        let tracks: [CueSheet.Track] = [
            .init(number: 1, file: "01.flac", sectors: 800),
            .init(number: 2, file: "02.flac", sectors: 900, indexes: [.init(number: 2, sectors: 300)]),
        ]
        let perTrack = CueSheet(tracks: tracks).text
        #expect(
            perTrack.contains("FILE \"02.flac\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n    INDEX 02 00:04:00\n")
        )
        var image = CueSheet(tracks: tracks)
        image.imageFile = "disc.flac"
        #expect(image.text.contains("  TRACK 02 AUDIO\n    INDEX 01 00:10:50\n    INDEX 02 00:14:50\n"))
    }

    /// A rip finds the index points, and the report, the log, and the CUE sheet have them.
    @Test func ripRecordsTheIndexPoints() async throws {
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        let (rip, events, _, root) = try await DiscRipTests().rip(
            prepare: { $0.indexes = [2: [1200]] }, configure: { $0.manualRelease = .manual(toc: toc) })
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try RipReport.read(from: rip.folder.appending(path: "disc.json"))
        #expect(report.tracks[1].indexes == [.init(number: 2, sectors: 400)])
        #expect(report.tracks[0].indexes == nil)
        #expect(
            report.markdown.contains("Index points after 01, from the start of the track: track 2 (02 at 0:05.25)."))
        let finished = events.compactMap { event -> String? in
            if case .trackFinished(let track, let summary, _) = event, track.number == 2 { return summary }
            return nil
        }
        #expect(finished.first?.contains("index points 02 at 00:05:25") == true)
        let disc = try RippedDisc(folder: rip.folder)
        var encoder = DiscEncoder(format: .flac)
        encoder.allowsUnverified = true
        let files = try encoder.encode(disc, into: root.appending(path: "library"))
        let folder = files[0].deletingLastPathComponent()
        let cue = try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasSuffix(".cue") }
        let text = try String(contentsOf: folder.appending(path: try #require(cue)), encoding: .utf8)
        #expect(text.contains("    INDEX 01 00:00:00\n    INDEX 02 00:05:25\n"))
    }

    /// When the Q subchannel near a track's start cannot be read, its pregap is unknown, not 0.
    @Test func pregapThatCannotBeFoundIsUnknown() async throws {
        let (rip, _, _, root) = try await DiscRipTests().rip(
            prepare: {
                $0.pregaps = [2: 75]
                $0.corruptQSectors = Set(650..<800)
            })
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try RipReport.read(from: rip.folder.appending(path: "disc.json"))
        #expect(report.tracks[1].pregapUnknown == true && report.tracks[1].pregapSectors == nil)
        #expect(report.tracks[0].pregapUnknown == nil)
        #expect(report.markdown.contains("Pregap unknown for track 2"))
        #expect(report.markdown.contains("| unknown |"))
    }

    @Test func padsTheEdgesThatTheOffsetMovesPastTheAudio() throws {
        let toc = try TOC(audioTrackStarts: [0, 800], leadOutLBA: 1700)
        #expect(
            DiscRip.paddedEdges(of: toc, readOffset: 6, tracks: [1, 2]) == [.init(track: 2, samples: 6, atEnd: true)])
        #expect(
            DiscRip.paddedEdges(of: toc, readOffset: -30, tracks: [1, 2]) == [
                .init(track: 1, samples: 30, atEnd: false)
            ])
        #expect(DiscRip.paddedEdges(of: toc, readOffset: 6, tracks: [1]) == [])
        #expect(DiscRip.paddedEdges(of: toc, readOffset: 0, tracks: [1, 2]) == [])
        // An Enhanced CD's audio ends before the session gap, at the end of its last audio track.
        let enhanced = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0),
                .init(number: 2, startLBA: 1000),
                .init(number: 3, startLBA: 2000 + CDDA.sessionGapSectors, kind: .data, session: 2),
            ], leadOutLBA: 20000)
        #expect(
            DiscRip.paddedEdges(of: enhanced, readOffset: 103, tracks: [1, 2]) == [
                .init(track: 2, samples: 103, atEnd: true)
            ])
    }

    @Test func ripReportsThePaddedEdge() async throws {
        let (rip, _, _, root) = try await DiscRipTests().rip()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try RipReport.read(from: rip.folder.appending(path: "disc.json"))
        #expect(report.paddedEdges == [.init(track: 2, samples: 6, atEnd: true)])
        #expect(report.markdown.contains("The last 6 samples of track 2 are silence"))
    }
}
