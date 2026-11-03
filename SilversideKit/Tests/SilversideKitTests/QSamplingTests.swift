import Foundation
import Testing

@testable import SilversideKit

/// A drive that reads at half speed with the Q subchannel gets Q from some chunks of the first
/// read only, and the whole Q subchannel of a track where those chunks show an index point.
struct QSamplingTests {
    func ripper(prepare: (SimulatedDrive) -> Void = { _ in }) throws -> (TrackRipper, SimulatedDrive, TOC) {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 0)
        prepare(drive)
        var ripper = TrackRipper(
            reader: AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false), records: [])
        ripper.qEvery = 6
        return (ripper, drive, toc)
    }

    @Test func takesQFromEveryNthChunk() throws {
        let (ripper, _, toc) = try ripper()
        let read = try ripper.reader.read(0..<(toc.leadOutLBA * 588), withC2: false, withQ: true, qEvery: 3)
        let chunk = ripper.reader.sectorsPerRead
        let sectors = read.q.compactMap(\.position).map(\.lba)
        #expect(!sectors.isEmpty && sectors.allSatisfy { ($0 / chunk) % 3 == 0 })
        #expect(
            sectors.count
                == stride(from: 0, to: toc.leadOutLBA, by: chunk * 3).map { min(chunk, toc.leadOutLBA - $0) }.reduce(
                    0, +))
    }

    /// The control bits come from the chunks with Q, and a track with no index needs no more.
    @Test func findsTheControlBitsFromSomeChunks() throws {
        let (ripper, drive, toc) = try ripper { $0.qControl = [2: 0x1] }
        let rip = try ripper.rip(toc.tracks[1])
        #expect(rip.subchannel?.hasPreEmphasis == true && !rip.qReadInFull)
        #expect(drive.qSectorsRead > 0 && drive.qSectorsRead < 900 / 4)
    }

    /// Index 02 lasts 30 sectors, between two chunks with Q; index 03 after it is long enough
    /// to show in one, so the track's whole Q subchannel is read, and both are found.
    @Test func readsQInFullWhereAnIndexShows() throws {
        let (ripper, drive, toc) = try ripper { $0.indexes = [2: [1000, 1030]] }
        var events = [RipEvent]()
        let rip = try ripper.rip(toc.tracks[1]) { events.append($0) }
        #expect(rip.qReadInFull)
        #expect(drive.qSectorsRead > 900)
        let indexes = PregapFinder.indexes(of: toc.tracks[1], in: toc, positions: rip.qPositions, drive: drive)
        #expect(indexes == [.init(number: 2, sectors: 200), .init(number: 3, sectors: 230)])
        #expect(events.contains { if case .readingIndexes(2, _) = $0 { true } else { false } })
    }

    /// Timed with sleeps, so other tests running at once make it a little noisy: it checks
    /// only which side of the line each drive falls.
    @Test func measuresTheCostOfQ() throws {
        for cost in [1.0, 2.2] {
            let (_, drive, toc) = try ripper {
                $0.readSpeed = 10
                $0.qReadCost = cost
            }
            let measured = try #require(QReadCost.measure(drive: drive, toc: toc))
            #expect(TrackRipper.qEvery(forReadCost: measured) == (cost > 1 ? 6 : 1), "\(measured) for \(cost)")
        }
        #expect(TrackRipper.qEvery(forReadCost: nil) == 1)
        #expect(TrackRipper.qEvery(forReadCost: 1.05) == 1)
        #expect(TrackRipper.qEvery(forReadCost: 2.2) == 6)
    }

    /// The rip measures a drive's cost once and keeps it in the profile; a slow one gets sampled reads.
    @Test func ripsWithTheProfilesCost() async throws {
        let (_, events, _, root) = try await DiscRipTests().rip(qReadCost: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = events.compactMap { if case .finished(_, _, let profile) = $0 { profile } else { nil } }.first
        #expect(profile?.qReadCost != nil)
        let store = try DriveProfileStore(url: root.appending(path: "DriveProfiles.json"))
        #expect(store.profile(vendor: "SIM", product: "DRIVE", revision: "1.0").qReadCost != nil)
        #expect(!events.contains { if case .qSubchannelSampled = $0 { true } else { false } })

        let (slow, slowEvents, _, slowRoot) = try await DiscRipTests().rip(qReadCost: 2.2) {
            $0.qControl = [2: 0x1]
        }
        defer { try? FileManager.default.removeItem(at: slowRoot) }
        #expect(slowEvents.contains { if case .qSubchannelSampled(2.2, 6) = $0 { true } else { false } })
        #expect(slow.report.tracks[1].preEmphasis && slow.report.tracks[1].subchannel?.hasPreEmphasis == true)
    }
}
