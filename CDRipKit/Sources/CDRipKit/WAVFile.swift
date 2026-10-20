import Foundation

/// Writes CD audio as a WAV file: 44.1 kHz, 16-bit, stereo PCM.
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

    /// Reads CD audio from a WAV file that holds 44.1 kHz, 16-bit, stereo PCM.
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
                isCDAudio =
                    uint16(body) == 1 && uint16(body + 2) == 2 && uint32(body + 4) == 44100
                    && uint16(body + 14) == 16
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
