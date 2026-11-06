import Foundation
import SilversideKit

/// Checks every private-stream packet in complete DVD sectors, including packets
/// after a system header. Shared by physical-disc and plain-directory reads.
enum DVDPackets {
    static func checkAudio(_ bytes: ArraySlice<UInt8>) throws {
        guard bytes.count % 2048 == 0 else { throw DVDError("Incomplete DVD sector.") }
        for base in stride(from: bytes.startIndex, to: bytes.endIndex, by: 2048) {
            guard bytes[base..<base + 4].elementsEqual([0, 0, 1, 0xba]) else { continue }
            let sectorEnd = base + 2048
            var position = base + 14 + Int(bytes[base + 13] & 7)
            while position + 6 <= sectorEnd,
                bytes[position..<position + 3].elementsEqual([0, 0, 1])
            {
                let stream = bytes[position + 3]
                if stream == 0xb9 { break }  // MPEG program end.
                let end = position + 6 + Int(bytes[position + 4]) * 256 + Int(bytes[position + 5])
                guard end <= sectorEnd else { throw DVDError("Invalid DVD packet length.") }
                if stream == 0xbd {
                    guard end >= position + 9 else { throw DVDError("Truncated DVD audio packet.") }
                    guard bytes[position + 6] & 0x30 == 0 else {
                        throw DVDError(
                            "Audio is still encrypted. Use --device with the original disc and drive access for CPPM authentication; a raw ISO or copied AUDIO_TS folder may be insufficient."
                        )
                    }
                }
                position = end
            }
        }
    }
}
