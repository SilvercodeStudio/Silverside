/// One record from an AccurateRip database file. A file holds one or more
/// records, and each record has one checksum for each track. A checksum can be
/// v1 or v2; the file does not say which.
public struct AccurateRipRecord: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        /// The number of submissions that agree on this checksum.
        public var confidence: Int
        public var checksum: UInt32
        /// The checksum of sector 450 of the track, which EAC uses to find a read offset.
        public var frame450Checksum: UInt32
    }

    public var discID: AccurateRipDiscID
    public var tracks: [Track]

    /// Parses a database file, as returned from `AccurateRipDiscID.databaseURL`.
    public static func records(from bytes: [UInt8]) throws(AccurateRipError) -> [AccurateRipRecord] {
        var records = [AccurateRipRecord]()
        var index = 0
        func uint32() -> UInt32 {
            defer { index += 4 }
            return bytes[index..<(index + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        while index < bytes.count {
            let trackCount = Int(bytes[index])
            guard trackCount > 0, bytes.count - index >= 13 + 9 * trackCount else { throw .malformedResponse }
            index += 1
            let id1 = uint32()
            let id2 = uint32()
            let freedbID = uint32()
            var tracks = [Track]()
            for _ in 0..<trackCount {
                let confidence = Int(bytes[index])
                index += 1
                tracks.append(Track(confidence: confidence, checksum: uint32(), frame450Checksum: uint32()))
            }
            let discID = AccurateRipDiscID(audioTrackCount: trackCount, id1: id1, id2: id2, freedbID: freedbID)
            records.append(AccurateRipRecord(discID: discID, tracks: tracks))
        }
        return records
    }
}

public enum AccurateRipError: Error, Equatable {
    case malformedResponse
}
