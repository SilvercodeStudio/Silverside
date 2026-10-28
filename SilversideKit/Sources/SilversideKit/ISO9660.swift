import Foundation

/// Reads the files of an ISO 9660 file system (with its Joliet names, if it has them) from a
/// data track's image, to copy them out. The track can start anywhere on the disc: the file
/// system's sector numbers count from the disc's start (an Enhanced CD's track is in its
/// second session, at sector 308636 on *Mirrorball*), so `startLBA` is taken off each.
public struct ISO9660Reader {
    public static let sectorSize = 2048

    let image: FileHandle
    let startLBA: Int
    let sectors: Int
    /// The root directory's extent and length, and whether names are Joliet's (UCS-2).
    let root: (lba: Int, length: Int)
    let joliet: Bool

    /// Reads the volume descriptors from sector 16 of the image. Nil if it has no ISO 9660 file system.
    public init?(image url: URL, startLBA: Int) throws {
        let handle = try FileHandle(forReadingFrom: url)
        image = handle
        self.startLBA = startLBA
        sectors = Int(try handle.seekToEnd()) / Self.sectorSize
        var primary: (lba: Int, length: Int)?
        var supplementary: (lba: Int, length: Int)?
        for sector in 16..<min(sectors, 32) {
            guard let descriptor = try? Self.read(handle, sector: sector, count: 1),
                descriptor[1...5].elementsEqual("CD001".utf8)
            else { break }
            let rootRecord = descriptor[156..<190]
            let extent = (Int(Self.uint32(rootRecord, at: 2)), Int(Self.uint32(rootRecord, at: 10)))
            switch descriptor[0] {
            case 1: primary = primary ?? extent
            // A supplementary descriptor with a UCS-2 escape sequence is Joliet's.
            case 2
            where descriptor[88] == 0x25 && descriptor[89] == 0x2F && [0x40, 0x43, 0x45].contains(descriptor[90]):
                supplementary = supplementary ?? extent
            case 255: break
            default: continue
            }
            if descriptor[0] == 255 { break }
        }
        guard let chosen = supplementary ?? primary else { return nil }
        root = chosen
        joliet = supplementary != nil
    }

    /// Copies every file into `folder`, which it makes, keeping the directories and the files'
    /// dates. Files whose data lies outside the image are left out and counted.
    public func extract(to folder: URL) throws -> (files: Int, bytes: Int, skipped: Int) {
        var totals = (files: 0, bytes: 0, skipped: 0)
        var visited = Set<Int>()
        try extract(directory: root, to: folder, visited: &visited, totals: &totals)
        return totals
    }

    private func extract(
        directory: (lba: Int, length: Int), to folder: URL, visited: inout Set<Int>,
        totals: inout (files: Int, bytes: Int, skipped: Int)
    ) throws {
        // A damaged or looping directory tree is not followed twice.
        guard visited.insert(directory.lba).inserted else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = directory.lba - startLBA
        let count = (directory.length + Self.sectorSize - 1) / Self.sectorSize
        guard first >= 0, first + count <= sectors else {
            totals.skipped += 1
            return
        }
        let data = try Self.read(image, sector: first, count: count)
        // A file in several extents has a record for each, all but the last flagged multi-extent.
        var pending: (name: String, extents: [(lba: Int, length: Int)])?
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            // Records do not cross sectors: a zero length means the rest of the sector is empty.
            guard length > 0 else {
                offset = (offset / Self.sectorSize + 1) * Self.sectorSize
                continue
            }
            guard offset + length <= data.count, length >= 34 else { break }
            let record = data[offset..<(offset + length)]
            offset += length
            let flags = record[record.startIndex + 25]
            let nameLength = Int(record[record.startIndex + 32])
            let nameBytes = record.dropFirst(33).prefix(nameLength)
            // "." and "..", and Apple's associated files (resource forks, beside the files).
            if nameLength == 1 && (nameBytes.first == 0 || nameBytes.first == 1) { continue }
            if flags & 0x04 != 0 { continue }
            guard let name = safeName(nameBytes, isDirectory: flags & 0x02 != 0) else { continue }
            let extent = (lba: Int(Self.uint32(record, at: 2)), length: Int(Self.uint32(record, at: 10)))
            if flags & 0x02 != 0 {
                try extract(
                    directory: extent, to: folder.appending(path: name, directoryHint: .isDirectory),
                    visited: &visited, totals: &totals)
                continue
            }
            var extents = pending?.name == name ? pending!.extents : []
            extents.append(extent)
            if flags & 0x80 != 0 {
                pending = (name, extents)
                continue
            }
            pending = nil
            let url = folder.appending(path: name)
            guard try write(extents, to: url) else {
                totals.skipped += 1
                continue
            }
            if let date = Self.date(record) {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            totals.files += 1
            totals.bytes += extents.reduce(0) { $0 + $1.length }
        }
    }

    /// Writes a file's extents one after another. False if one lies outside the image.
    private func write(_ extents: [(lba: Int, length: Int)], to url: URL) throws -> Bool {
        for extent in extents {
            let sectorsNeeded = (extent.length + Self.sectorSize - 1) / Self.sectorSize
            guard extent.lba - startLBA >= 0, extent.lba - startLBA + sectorsNeeded <= sectors else { return false }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        for extent in extents {
            var left = extent.length
            var sector = extent.lba - startLBA
            // A megabyte at a time, so a large video does not sit in memory whole.
            while left > 0 {
                let count = min(512, (left + Self.sectorSize - 1) / Self.sectorSize)
                let data = try Self.read(image, sector: sector, count: count)
                try output.write(contentsOf: data.prefix(left))
                left -= min(left, data.count)
                sector += count
            }
        }
        return true
    }

    /// The record's name as a file name: Joliet's UCS-2, or ISO 9660's with its ";1" version
    /// and a trailing dot taken off. A name that could leave the folder is refused.
    private func safeName(_ bytes: some Collection<UInt8>, isDirectory: Bool) -> String? {
        var name: String
        if joliet {
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { index in
                UInt16(bytes[bytes.index(bytes.startIndex, offsetBy: index)]) << 8
                    | UInt16(bytes[bytes.index(bytes.startIndex, offsetBy: index + 1)])
            }
            name = String(decoding: units, as: UTF16.self)
        } else {
            name = String(decoding: bytes, as: UTF8.self)
        }
        if !isDirectory, let semicolon = name.lastIndex(of: ";") { name = String(name[..<semicolon]) }
        if !isDirectory, !joliet, name.hasSuffix(".") { name.removeLast() }
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }

    /// The record's date: years since 1900, month, day, hour, minute, second, and the offset
    /// from GMT in quarter hours.
    static func date(_ record: ArraySlice<UInt8>) -> Date? {
        let base = record.startIndex + 18
        var components = DateComponents()
        components.year = 1900 + Int(record[base])
        components.month = Int(record[base + 1])
        components.day = Int(record[base + 2])
        components.hour = Int(record[base + 3])
        components.minute = Int(record[base + 4])
        components.second = Int(record[base + 5])
        components.timeZone = TimeZone(secondsFromGMT: Int(Int8(bitPattern: record[base + 6])) * 15 * 60)
        guard let month = components.month, (1...12).contains(month) else { return nil }
        return Calendar(identifier: .gregorian).date(from: components)
    }

    /// The little-endian half of a both-endian 32-bit number.
    static func uint32(_ bytes: some Collection<UInt8>, at offset: Int) -> UInt32 {
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[bytes.index(start, offsetBy: $1)]) << (8 * $1) }
    }

    static func read(_ handle: FileHandle, sector: Int, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: UInt64(sector * sectorSize))
        let data = try handle.read(upToCount: count * sectorSize) ?? Data()
        guard data.count == count * sectorSize else { throw CocoaError(.fileReadCorruptFile) }
        return [UInt8](data)
    }
}
