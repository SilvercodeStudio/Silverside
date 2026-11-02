import CryptoKit
import Darwin
import Foundation
import SilversideKit

/// Filesystem reads for already-unencrypted AUDIO_TS folders. Never decrypts.
struct DVDDirectory {
    let root: URL
    init?(_ source: String) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: source)
        root = url.lastPathComponent.uppercased() == "AUDIO_TS" ? url : url.appendingPathComponent("AUDIO_TS")
    }
    func information(_ title: Int) throws -> Data {
        let name = title == 0 ? "AUDIO_TS.IFO" : String(format: "ATS_%02d_0.IFO", title)
        let file = root.appendingPathComponent(name)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 2048, size <= 16 * 1024 * 1024 else {
            throw DVDError("Invalid or oversized DVD information file.")
        }
        return try Data(contentsOf: file)
    }
    func files(_ title: Int) throws -> [(URL, Int)] {
        var result = [(URL, Int)]()
        var ended = false
        for index in 1...9 {
            let url = root.appendingPathComponent(String(format: "ATS_%02d_%d.AOB", title, index))
            guard FileManager.default.fileExists(atPath: url.path) else {
                ended = true
                continue
            }
            guard !ended else { throw DVDError("Missing part of an AUDIO_TS title set.") }
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes % 2048 == 0 else { throw DVDError("Incomplete AOB file.") }
            result.append((url, bytes / 2048))
        }
        guard !result.isEmpty else { throw DVDError("No AOB files in title set \(title).") }
        return result
    }
    func inventory(source: String) throws -> DVDInventory {
        let manager = try information(0)
        let count = try DVDNavigation.titleSetCount(manager: manager)
        var hash = SHA256()
        hash.update(data: manager)
        var presentations = [DVDPresentation]()
        for title in 1...count {
            let data = try information(title)
            hash.update(data: data)
            presentations += try DVDNavigation.presentations(
                ifo: data, titleSet: title, audioSectors: files(title).reduce(0) { $0 + $1.1 })
        }
        return DVDInventory(
            source: source, volume: root.deletingLastPathComponent().lastPathComponent,
            fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            libraryPath: "Plain AUDIO_TS filesystem reader (no decryption)", presentations: presentations)
    }
    func copy(title: Int, first: Int, count: Int, output: String) throws {
        let parts = try files(title)
        let total = parts.reduce(0) { $0 + $1.1 }
        guard first >= 0, first < total, count > 0, count <= total - first else {
            throw DVDError("Invalid audio read range.")
        }
        let fd = Darwin.open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DVDError("Cannot create new audio file.") }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? out.close() }
        var skip = first
        var remaining = count
        for (url, sectors) in parts {
            if skip >= sectors {
                skip -= sectors
                continue
            }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(skip) * 2048)
            var available = min(sectors - skip, remaining)
            while available > 0 {
                let blocks = min(available, 128)
                guard let data = try input.read(upToCount: blocks * 2048), data.count == blocks * 2048 else {
                    throw DVDError("Short AOB file read.")
                }
                let bytes = [UInt8](data)
                for base in stride(from: 0, to: data.count, by: 2048) {
                    if bytes[base..<base + 4].elementsEqual([0, 0, 1, 0xba]) {
                        var pos = base + 14 + Int(bytes[base + 13] & 7)
                        while pos + 9 <= base + 2048, bytes[pos..<pos + 3].elementsEqual([0, 0, 1]) {
                            if bytes[pos + 3] == 0xbd, bytes[pos + 6] & 0x30 != 0 {
                                throw DVDError(
                                    "AUDIO_TS still contains encrypted audio. Use --device with the original disc for CPPM authentication."
                                )
                            }
                            let end = pos + 6 + Int(bytes[pos + 4]) * 256 + Int(bytes[pos + 5])
                            guard end > pos, end <= base + 2048 else { break }
                            pos = end
                        }
                    }
                }
                try out.write(contentsOf: data)
                available -= blocks
                remaining -= blocks
            }
            if remaining == 0 { break }
            skip = 0
        }
        guard remaining == 0 else { throw DVDError("Incomplete AUDIO_TS files.") }
        try out.synchronize()
    }
}
