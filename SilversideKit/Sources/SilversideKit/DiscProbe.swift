/// A short look at a disc's audio as it is read, before a rip, so that the app can show at
/// once what kind of disc it is (`DiscLogo`): two seconds from each of the first three audio
/// tracks, for HDCD codes and a DTS stream, and their raw subchannel, for CD+G graphics
/// (and on a CD+G disc, a second of every track's, for CD+EG graphics).
public struct DiscProbe: Equatable, Sendable {
    /// HDCD codes in the audio read.
    public var hdcd = false
    /// The HDCD codes found in each track's few seconds, by track number. A few seconds tell
    /// whether there are codes and what they mostly ask for; a gain adjustment elsewhere in a
    /// track, or in a later track, shows only in a rip.
    public var hdcdCodes: [Int: HDCDCodes] = [:]
    /// A DTS stream in place of the audio.
    public var dts = false
    /// CD+G graphics in the subchannel; nil if the drive did not give the raw subchannel.
    public var cdGraphics: Bool?
    /// CD+EG graphics in the subchannel (`CDGraphics.holdsExtendedGraphics`).
    public var cdExtendedGraphics = false
    /// The tracks whose audio was read: none if every read failed, and nothing is known.
    public var tracksRead = 0

    public init(
        hdcd: Bool = false, dts: Bool = false, cdGraphics: Bool? = nil, cdExtendedGraphics: Bool = false,
        tracksRead: Int = 1
    ) {
        self.hdcd = hdcd
        self.dts = dts
        self.cdGraphics = cdGraphics
        self.cdExtendedGraphics = cdExtendedGraphics
        self.tracksRead = tracksRead
    }

    /// What the HDCD codes found ask for, for people: "peak extend", "peak extend, gain", or
    /// "nothing" (no peak extend or gain in the audio looked at). Nil if no codes were found.
    public var hdcdFeatures: String? {
        guard hdcd else { return nil }
        let codes = hdcdCodes.values
        var features = [String]()
        if codes.contains(where: { $0.peakExtend != .never }) { features.append("peak extend") }
        if codes.contains(where: { $0.maxGainAdjustment < 0 }) { features.append("gain") }
        return features.isEmpty ? "nothing" : features.joined(separator: ", ")
    }

    /// The sectors read from each track: 2 seconds, which hold about 40 HDCD packets and
    /// 86 DTS frames.
    static let sectors = 150
    /// Where in a track the read starts: 10 seconds in (past a quiet start), or a third of
    /// the way into a shorter track.
    static let start = 10 * CDDA.sectorsPerSecond

    /// Reads the first `tracks` audio tracks. A read that fails leaves its track out: this is
    /// a look, not a rip. `stop` ends it early, as a rip that starts does. On a disc with
    /// CD+G graphics, it then reads a second of the other tracks' subchannel until it finds
    /// CD+EG graphics: a CD+EG disc can have none in its first tracks (*The CD Graphics World*
    /// has them in tracks 2, 3, 7, and 8, and in a second of track 8 only).
    public static func probe(
        _ drive: any CDDrive, toc: TOC, tracks: Int = 3, stop: StopToken? = nil
    ) -> DiscProbe {
        var result = DiscProbe(tracksRead: 0)
        // The drive's raw subchannel, until it refuses it or both kinds of graphics are found.
        var readsSubchannel = true
        func lookAtSubchannel(_ pw: [UInt8]) {
            if result.cdGraphics != true { result.cdGraphics = CDGraphics.holdsGraphics(pw) }
            if CDGraphics.holdsExtendedGraphics(pw) { result.cdExtendedGraphics = true }
            if result.cdGraphics == true && result.cdExtendedGraphics { readsSubchannel = false }
        }
        // A second of a track's subchannel (300 packs, plenty; its reads are slower than
        // audio's), and whether every read of it worked. It comes before the track's audio:
        // the MATSHITA answers a subchannel read of sectors it has just read as audio with the
        // wrong subchannel (2026-11-02, a CD+EG disc: the same packs for every track).
        func subchannel(from first: Int, in range: Range<Int>) -> (pw: [UInt8], allRead: Bool) {
            var pw = [UInt8]()
            var lba = first
            while lba < min(first + CDDA.sectorsPerSecond, range.upperBound), stop?.isStopped != true {
                let piece = min(25, min(first + CDDA.sectorsPerSecond, range.upperBound) - lba)
                guard let bytes = try? drive.readSubchannelPW(at: lba, count: piece) else { return (pw, false) }
                pw += bytes
                lba += piece
            }
            return (pw, true)
        }
        for track in toc.audioTracks.prefix(tracks) {
            guard stop?.isStopped != true else { break }
            let range = toc.sectorRange(of: track)
            let first = range.lowerBound + min(start, range.count / 3)
            let count = min(sectors, range.upperBound - first)
            guard count > 0 else { continue }
            var pw = [UInt8]()
            if readsSubchannel {
                let read = subchannel(from: first, in: range)
                pw = read.pw
                if !read.allRead { readsSubchannel = false }
            }
            var audio = [UInt8]()
            var lba = first
            // In pieces of the size a rip reads, so that a stop does not wait long.
            while lba < first + count, stop?.isStopped != true {
                let piece = min(25, first + count - lba)
                guard let bytes = try? drive.readAudioSectors(at: lba, count: piece) else { break }
                audio += bytes
                lba += piece
            }
            guard !audio.isEmpty else { continue }
            result.tracksRead += 1
            let samples = CDDA.samples(fromSectorBytes: audio)
            if let codes = HDCDCodes.scan(samples) {
                result.hdcd = true
                result.hdcdCodes[track.number] = codes
            }
            if !result.dts, DTSStream.isStream(samples) { result.dts = true }
            if !pw.isEmpty { lookAtSubchannel(pw) }
        }
        // CD+EG graphics on a CD+G disc, from the subchannel alone.
        if result.cdGraphics == true {
            for track in toc.audioTracks.dropFirst(tracks) {
                guard readsSubchannel, stop?.isStopped != true else { break }
                let range = toc.sectorRange(of: track)
                let pw = subchannel(from: range.lowerBound + min(start, range.count / 3), in: range).pw
                if !pw.isEmpty { lookAtSubchannel(pw) }
            }
        }
        return result
    }
}
