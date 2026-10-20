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
}
