import Testing

@testable import SilversideKit

struct CacheProbeTests {
    /// A probe that times reads of a simulated drive: 1 ms from the cache, 100 ms from the disc.
    func probe(cacheSectors: Int) throws -> (CacheProbe, TOC) {
        let (toc, samples) = try makeDisc(trackSectors: [12_000, 14_000])
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.cacheSectors = cacheSectors
        let probe = CacheProbe { lba, count in
            _ = try drive.readAudioSectors(at: lba, count: count)
            return drive.lastReadWasCached ? .milliseconds(1) : .milliseconds(100)
        }
        return (probe, toc)
    }

    @Test(arguments: [100, 600, 1800, 4000])
    func findsTheCacheSize(sectors: Int) throws {
        let (probe, toc) = try probe(cacheSectors: sectors)
        let found = try #require(try probe.cacheSectors(toc: toc))
        #expect((sectors...(sectors + probe.precision)).contains(found))
    }

    @Test func findsNoCacheLargerThanTheLimit() throws {
        var (probe, toc) = try probe(cacheSectors: 30_000)
        probe.maximumSectors = 8_000
        #expect(try probe.cacheSectors(toc: toc) == nil)
    }
}

struct DriveReportTests {
    @Test func checksASimulatedDrive() throws {
        let (toc, samples) = try makeDisc(trackSectors: [12_000, 14_000])
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.reportsC2 = true
        var report = DriveReport(registry: ["Device: Vendor Name": "SIM"], profile: nil)
        report.check(drive)
        #expect(report.checks.map(\.name).count == 7)
        #expect(report.checks.allSatisfy { $0.passed })
        #expect(report.disc["musicBrainzDiscID"] == toc.musicBrainzDiscID)
        #expect(report.checks.first { $0.name.hasPrefix("Read past") }?.result.hasPrefix("does not read") == true)
        #expect(!report.mac.isEmpty)
    }
}
