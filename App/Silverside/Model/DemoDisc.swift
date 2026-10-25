#if DEBUG
    import SilversideDarwin
    import SilversideKit
    import Foundation

    /// A simulated drive with a short disc, for work on the app without hardware: the
    /// release is *Cornell 5/8/77* disc 1 from the engine's test fixtures, and the audio is
    /// a tone, with a few unstable sectors so that the secure rip has something to re-read.
    /// The rip runs offline, so no service is asked about a disc that does not exist.
    enum DemoDisc {
        /// The disc's MusicBrainz offsets (with the 150-sector lead-in) and length, scaled down.
        private static let offsets = [150, 25220, 61075, 82890, 116599, 145802, 173575, 189016, 210578, 236749, 251121]
        private static let leadOut = 301_681
        private static let scale = 24

        static func slot() -> DriveSlot? {
            let starts = offsets.map { ($0 - CDDA.leadInSectors) / scale }
            guard let toc = try? TOC(audioTrackStarts: starts, leadOutLBA: leadOut / scale) else { return nil }
            var samples = [UInt32](repeating: 0, count: toc.leadOutLBA * CDDA.samplesPerSector)
            let hdcd = hdcdBits(count: samples.count)
            for index in samples.indices {
                // Two tones, with a slow beat between the channels, and HDCD codes in the lowest bit.
                let bit: Int16 = hdcd[index] ? 1 : 0
                let left = Int16(truncatingIfNeeded: Int(12000 * sin(Double(index) * 0.031))) & ~1 | bit
                let right = Int16(truncatingIfNeeded: Int(9000 * sin(Double(index) * 0.047))) & ~1 | bit
                samples[index] = UInt32(UInt16(bitPattern: left)) | UInt32(UInt16(bitPattern: right)) << 16
            }
            let image = samples
            // Track 3 has a sector that reads wrong once in two, and track 5 one that fails twice, then reads.
            let unstable: Set<Int> = [starts[2] + 200]
            let failing = [starts[4] + 50: 2]
            let makeDrive: @Sendable () throws -> any CDDrive = {
                let drive = SimulatedDrive(toc: toc, samples: image, readOffset: 6)
                drive.unstableSectors = unstable
                drive.failingReads = failing
                drive.reportsC2 = true
                drive.readSpeed = 40
                return drive
            }
            var disc = DiscInfo(bsdName: nil, toc: toc, mcn: nil, cdText: demoCDText)
            if let release = fixtureRelease() {
                disc.release = release
                disc.medium = release.media.first
                disc.releases = [release]
                disc.lookup = .found
            }
            let device = OpticalDrive(
                vendor: "Silverside", product: "Simulated Drive", revision: "demo", interconnect: "None",
                location: "Internal")
            let slot = DriveSlot(id: "demo", device: device, disc: disc, makeDrive: makeDrive)
            if UserDefaults.standard.integer(forKey: "demoCDText") == 2 { slot.namesSource = .cdText }
            return slot
        }

        /// `-demoCDText 1` gives the disc CD-Text, with the venue in each title as some box sets
        /// have it, to show the Names from picker; `-demoCDText 2` shows the CD-Text names.
        private static var demoCDText: CDText? {
            guard UserDefaults.standard.integer(forKey: "demoCDText") > 0 else { return nil }
            var text = CDText()
            text.titles[0] = "Cornell 5/8/77"
            text.performers[0] = "Grateful Dead"
            for track in 1...11 {
                text.titles[track] = "Track \(track) (Live at Barton Hall, Cornell University, 5/8/1977)"
            }
            return text
        }

        /// HDCD codes that ask for nothing, as the real disc has them: a packet (a sync word and
        /// an 8-bit code) ten times a second, scrambled as the decoder expects (see `HDCDTests`).
        /// The last tenth of a second has none, so that the disc's end cuts no packet short:
        /// silence in place of its code would read as a code that asks for a gain.
        /// `-demoHDCDCode 19` gives another code (type A: 16 is peak extend, 1 to 7 a gain), so
        /// that the rip asks whether to decode.
        private static func hdcdBits(count: Int) -> [Bool] {
            let code = UInt64(UserDefaults.standard.integer(forKey: "demoHDCDCode") & 0x37)
            let packet = UInt64(0x7e0f_a005) << 8 | code
            let block = (0..<4410).map { $0 >= 4370 && packet >> (4409 - $0) & 1 == 1 }
            var plain = [Bool]()
            while plain.count + 2 * block.count <= count { plain += block }
            plain += [Bool](repeating: false, count: count - plain.count)
            var bits = [Bool]()
            bits.reserveCapacity(count)
            for bit in plain {
                let n = bits.count
                let earlier = (n >= 5 && bits[n - 5]) != (n >= 23 && bits[n - 23])
                bits.append(bit != earlier)
            }
            return bits
        }

        private static func fixtureRelease() -> MusicBrainzRelease? {
            let file = URL(filePath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "SilversideKit/Tests/SilversideKitTests/Resources/MusicBrainz/cornell-1977-disc1.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? MusicBrainzClient.lookup(fromJSON: data).releases.first
        }
    }
#endif
