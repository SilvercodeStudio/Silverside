import Foundation
import Testing

@testable import SilversideKit

/// Files copied out of a data track's ISO 9660 file system, whose sector numbers count from the disc's start.
struct ISO9660Tests {
    /// A directory record: its extent and length both-endian, a date, flags, and the name.
    static func record(_ name: [UInt8], lba: Int, length: Int, flags: UInt8 = 0) -> [UInt8] {
        func both(_ value: Int) -> [UInt8] {
            let v = UInt32(value)
            let little = (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            return little + little.reversed()
        }
        var bytes: [UInt8] =
            [0, 0] + both(lba) + both(length) + [99, 5, 26, 12, 30, 0, 0] + [flags, 0, 0, 1, 0, 0, 1]
        bytes += [UInt8(name.count)] + name
        if bytes.count % 2 == 1 { bytes.append(0) }
        bytes[0] = UInt8(bytes.count)
        return bytes
    }

    static func ucs2(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    /// An image of a track at `start` on the disc: a primary volume and a Joliet one, a root
    /// with a file and a folder, and the folder with a file and an Apple associated file.
    static func image(start: Int) -> Data {
        var sectors = [[UInt8]](repeating: [UInt8](repeating: 0, count: 2048), count: 26)
        func descriptor(_ type: UInt8, root: Int, joliet: Bool = false) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 2048)
            bytes[0] = type
            bytes.replaceSubrange(1...5, with: Array("CD001".utf8))
            bytes[6] = 1
            if joliet { bytes.replaceSubrange(88...90, with: [0x25, 0x2F, 0x45]) }
            bytes.replaceSubrange(156..<190, with: record([0], lba: start + root, length: 2048, flags: 2))
            return bytes
        }
        sectors[16] = descriptor(1, root: 19)
        sectors[17] = descriptor(2, root: 21, joliet: true)
        sectors[18] = [255] + Array("CD001".utf8) + [UInt8](repeating: 0, count: 2042)
        func directory(_ records: [[UInt8]], parent: Int) -> [UInt8] {
            let bytes =
                record([0], lba: start + parent, length: 2048, flags: 2)
                + record([1], lba: start + parent, length: 2048, flags: 2) + records.flatMap { $0 }
            return bytes + [UInt8](repeating: 0, count: 2048 - bytes.count)
        }
        // The primary volume's names, 8.3 with versions.
        sectors[19] = directory(
            [
                record(Array("README.TXT;1".utf8), lba: start + 24, length: 5),
                record(Array("DOCS".utf8), lba: start + 20, length: 2048, flags: 2),
            ], parent: 19)
        sectors[20] = directory([record(Array("A.TXT;1".utf8), lba: start + 25, length: 3)], parent: 19)
        // Joliet's names for the same files.
        sectors[21] = directory(
            [
                record(ucs2("Read Me.txt;1"), lba: start + 24, length: 5),
                record(ucs2("Docs & Notes"), lba: start + 22, length: 2048, flags: 2),
            ], parent: 21)
        sectors[22] = directory(
            [
                record(ucs2("a.txt;1"), lba: start + 23, length: 4, flags: 4),
                record(ucs2("a.txt;1"), lba: start + 25, length: 3),
            ], parent: 21)
        sectors[24].replaceSubrange(0..<5, with: Array("hello".utf8))
        sectors[25].replaceSubrange(0..<3, with: Array("abc".utf8))
        return Data(sectors.flatMap { $0 })
    }

    @Test func copiesTheFilesWithJolietNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "Track 15.iso")
        try Self.image(start: 308_636).write(to: image)
        let reader = try #require(try ISO9660Reader(image: image, startLBA: 308_636))
        let out = root.appending(path: "Data track")
        let totals = try reader.extract(to: out)
        #expect(totals.files == 2 && totals.bytes == 8 && totals.skipped == 0)
        #expect(try String(contentsOf: out.appending(path: "Read Me.txt"), encoding: .utf8) == "hello")
        // The associated file (a resource fork) is left out; the data fork keeps its name.
        #expect(try String(contentsOf: out.appending(path: "Docs & Notes/a.txt"), encoding: .utf8) == "abc")
        let date =
            try FileManager.default.attributesOfItem(atPath: out.appending(path: "Read Me.txt").path)[
                .modificationDate] as? Date
        #expect(
            date
                == Calendar(identifier: .gregorian).date(
                    from: DateComponents(timeZone: .gmt, year: 1999, month: 5, day: 26, hour: 12, minute: 30)))
    }

    /// The same image read with the wrong start finds its directories outside the image, and copies nothing.
    @Test func needsTheTracksStart() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "Track 15.iso")
        try Self.image(start: 308_636).write(to: image)
        let totals = try #require(try ISO9660Reader(image: image, startLBA: 0)).extract(to: root.appending(path: "out"))
        #expect(totals.files == 0 && totals.skipped == 1)
        // An image with no ISO 9660 file system has no reader.
        try Data(count: 40 * 2048).write(to: image)
        #expect(try ISO9660Reader(image: image, startLBA: 0) == nil)
    }
}
