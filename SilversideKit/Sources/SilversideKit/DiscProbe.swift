/// A short look at a disc's audio as it is read, before a rip, so that the app can show at
/// once what kind of disc it is (`DiscLogo`): two seconds from each of the first three audio
/// tracks, for HDCD codes and a DTS stream, and their raw subchannel, for CD+G graphics.
public struct DiscProbe: Equatable, Sendable {
    /// HDCD codes in the audio read.
    public var hdcd = false
    /// A DTS stream in place of the audio.
    public var dts = false
    /// CD+G graphics in the subchannel; nil if the drive did not give the raw subchannel.
    public var cdGraphics: Bool?
    /// The tracks whose audio was read: none if every read failed, and nothing is known.
    public var tracksRead = 0

    public init(hdcd: Bool = false, dts: Bool = false, cdGraphics: Bool? = nil, tracksRead: Int = 1) {
        self.hdcd = hdcd
        self.dts = dts
        self.cdGraphics = cdGraphics
        self.tracksRead = tracksRead
    }

    /// The sectors read from each track: 2 seconds, which hold about 40 HDCD packets and
    /// 86 DTS frames.
    static let sectors = 150
    /// Where in a track the read starts: 10 seconds in (past a quiet start), or a third of
    /// the way into a shorter track.
    static let start = 10 * CDDA.sectorsPerSecond

    /// Reads the first `tracks` audio tracks. A read that fails leaves its track out: this is
    /// a look, not a rip. `stop` ends it early, as a rip that starts does.
    public static func probe(
        _ drive: any CDDrive, toc: TOC, tracks: Int = 3, stop: StopToken? = nil
    ) -> DiscProbe {
        var result = DiscProbe(tracksRead: 0)
        // The drive's raw subchannel, until it refuses it or graphics are found.
        var readsSubchannel = true
        for track in toc.audioTracks.prefix(tracks) {
            guard stop?.isStopped != true else { break }
            let range = toc.sectorRange(of: track)
            let first = range.lowerBound + min(start, range.count / 3)
            let count = min(sectors, range.upperBound - first)
            guard count > 0 else { continue }
            var audio = [UInt8]()
            var pw = [UInt8]()
            var lba = first
            // In pieces of the size a rip reads, so that a stop does not wait long.
            while lba < first + count, stop?.isStopped != true {
                let piece = min(25, first + count - lba)
                guard let bytes = try? drive.readAudioSectors(at: lba, count: piece) else { break }
                audio += bytes
                // A second of subchannel is 300 packs, plenty; its reads are slower than audio's.
                if readsSubchannel, lba < first + CDDA.sectorsPerSecond {
                    if let bytes = try? drive.readSubchannelPW(at: lba, count: piece) {
                        pw += bytes
                    } else {
                        readsSubchannel = false
                    }
                }
                lba += piece
            }
            guard !audio.isEmpty else { continue }
            result.tracksRead += 1
            let samples = CDDA.samples(fromSectorBytes: audio)
            if !result.hdcd, HDCDCodes.scan(samples) != nil { result.hdcd = true }
            if !result.dts, DTSStream.isStream(samples) { result.dts = true }
            if !pw.isEmpty {
                result.cdGraphics = CDGraphics.holdsGraphics(pw)
                if result.cdGraphics == true { readsSubchannel = false }
            }
        }
        return result
    }
}
