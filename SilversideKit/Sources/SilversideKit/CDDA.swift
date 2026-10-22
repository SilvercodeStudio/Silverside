/// Constants of the Red Book audio CD format.
///
/// In this package, a "sample" is one stereo frame: a 16-bit left value and a
/// 16-bit right value. This agrees with AccurateRip and EAC terms. A sample is
/// stored as a `UInt32` with the left value in the low 16 bits, which is the
/// little-endian byte order that drives return.
public enum CDDA {
    public static let bytesPerSector = 2352
    public static let bytesPerSample = 4
    public static let samplesPerSector = 588
    /// C2 error flags for one sector: one bit for each byte.
    public static let errorFlagBytesPerSector = bytesPerSector / 8
    public static let sectorsPerSecond = 75

    /// The 2-second lead-in before LBA 0. MusicBrainz and freedb offsets include it.
    public static let leadInSectors = 150

    /// The gap between the audio session and the data session of an enhanced CD.
    public static let sessionGapSectors = 11400

    /// Converts raw sector bytes to samples.
    public static func samples(fromSectorBytes bytes: [UInt8]) -> [UInt32] {
        precondition(bytes.count % bytesPerSample == 0)
        let count = bytes.count / bytesPerSample
        return bytes.withUnsafeBytes { raw in
            (0..<count).map {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * bytesPerSample, as: UInt32.self))
            }
        }
    }
}
