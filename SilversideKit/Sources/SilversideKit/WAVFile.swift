import Foundation

/// Writes CD audio as a WAV file: 44.1 kHz, 16-bit, stereo PCM (or 24-bit, for an HDCD decode).
public enum WAVFile {
    public static func data(for samples: [UInt32]) -> Data {
        let dataSize = UInt32(samples.count * CDDA.bytesPerSample)
        var data = Data(capacity: 44 + Int(dataSize))
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)  // PCM
        append16(2)  // channels
        append32(44100)
        append32(44100 * UInt32(CDDA.bytesPerSample))  // bytes per second
        append16(UInt16(CDDA.bytesPerSample))  // bytes per frame
        append16(16)  // bits per sample
        append("data")
        append32(dataSize)
        // A sample's left value is in its low 16 bits, so its little-endian bytes are
        // the WAV frame. Macs are little-endian, so the bytes in memory are already in order.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public static func write(_ samples: [UInt32], to url: URL) throws {
        try data(for: samples).write(to: url, options: .atomic)
    }

    /// A 24-bit WAV file of `values` (`TrackPCM.wide`: each value's high 24 bits). It has the
    /// extensible format (tag 0xFFFE, PCM subformat), as Microsoft asks for more than 16 bits.
    public static func data(forWide values: [Int32]) -> Data {
        let dataSize = UInt32(values.count * 3)
        var data = Data(capacity: 68 + Int(dataSize))
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(60 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(40)
        append16(0xFFFE)  // extensible
        append16(2)  // channels
        append32(44100)
        append32(44100 * 6)  // bytes per second
        append16(6)  // bytes per frame
        append16(24)  // bits per sample
        append16(22)  // the size of the extension
        append16(24)  // valid bits per sample
        append32(3)  // channel mask: front left, front right
        // The PCM subformat GUID, 00000001-0000-0010-8000-00AA00389B71.
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71])
        append("data")
        append32(dataSize)
        var bytes = [UInt8](repeating: 0, count: Int(dataSize))
        for (index, value) in values.enumerated() {
            let bits = UInt32(bitPattern: value)
            bytes[3 * index] = UInt8(truncatingIfNeeded: bits >> 8)
            bytes[3 * index + 1] = UInt8(truncatingIfNeeded: bits >> 16)
            bytes[3 * index + 2] = UInt8(truncatingIfNeeded: bits >> 24)
        }
        data.append(contentsOf: bytes)
        return data
    }

    /// Writes 16-bit or 24-bit audio as a WAV file.
    public static func write(_ pcm: TrackPCM, to url: URL) throws {
        switch pcm {
        case .cd(let samples): try write(samples, to: url)
        case .wide(let values): try data(forWide: values).write(to: url, options: .atomic)
        }
    }

    /// Reads CD audio from a WAV file that holds 44.1 kHz, 16-bit, stereo PCM, in the plain
    /// form or the extensible form (format tag 0xFFFE with the PCM subformat) that some
    /// programs write.
    public static func read(_ url: URL) throws -> [UInt32] {
        let bytes = [UInt8](try Data(contentsOf: url))
        func uint32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        func uint16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8)
        else { throw WAVFileError.notCDAudio(url) }
        // Walk the chunks: fmt must be CD audio, and data holds the samples.
        var at = 12
        var isCDAudio = false
        while at + 8 <= bytes.count {
            let size = uint32(at + 4)
            let body = at + 8
            if bytes[at..<(at + 4)].elementsEqual("fmt ".utf8), body + 16 <= bytes.count {
                let tag = uint16(body)
                // In the extensible form, the subformat's first two bytes are the format tag.
                let isPCM =
                    tag == 1 || (tag == 0xFFFE && size >= 40 && body + 26 <= bytes.count && uint16(body + 24) == 1)
                isCDAudio = isPCM && uint16(body + 2) == 2 && uint32(body + 4) == 44100 && uint16(body + 14) == 16
            } else if bytes[at..<(at + 4)].elementsEqual("data".utf8) {
                guard isCDAudio, body + size <= bytes.count, size % CDDA.bytesPerSample == 0 else { break }
                return CDDA.samples(fromSectorBytes: Array(bytes[body..<(body + size)]))
            }
            at = body + size + size % 2
        }
        throw WAVFileError.notCDAudio(url)
    }
}

public enum WAVFileError: Error, CustomStringConvertible {
    case notCDAudio(URL)

    public var description: String {
        switch self {
        case .notCDAudio(let url): "\(url.path) is not a WAV file of CD audio"
        }
    }
}
