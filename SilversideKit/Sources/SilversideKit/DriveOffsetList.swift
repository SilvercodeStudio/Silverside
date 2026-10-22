import Foundation

/// AccurateRip's list of drive read offsets (DriveOffsets.bin).
public struct DriveOffsetList: Sendable {
    public struct Entry: Equatable, Sendable {
        public var vendor: String
        public var product: String
        public var offset: Int
        public var submissions: Int
    }

    public static let url = URL(string: "http://www.accuraterip.com/accuraterip/DriveOffsets.bin")!

    /// Vendor names that drives report, and the names that the list can use for the same drives.
    static let vendorAliases: [String: [String]] = [
        "MATSHITA": ["PANASONIC", "HP"],
        "HL-DT-ST": ["LG ELECTRONICS", "HP HLDS", "HP", "LG"],
    ]

    public let entries: [Entry]

    /// Parses the file: 69-byte records with a little-endian 16-bit offset, a
    /// 32-byte "Vendor - Product" name, and a little-endian 32-bit submission count.
    public init(bytes: [UInt8]) throws(DriveOffsetListError) {
        let recordSize = 69
        guard !bytes.isEmpty, bytes.count % recordSize == 0 else { throw .malformed }
        entries = stride(from: 0, to: bytes.count, by: recordSize).map { start in
            let offset = Int(Int16(bitPattern: UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8))
            let nameBytes = bytes[(start + 2)..<(start + 34)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            // Some names have no vendor and start with "- ".
            let separator = name.range(of: " - ") ?? (name.hasPrefix("- ") ? name.range(of: "- ") : nil)
            let vendor = separator.map { String(name[..<$0.lowerBound]) } ?? ""
            let product = separator.map { String(name[$0.upperBound...]) } ?? name
            let submissions = (0..<4).reduce(0) { $0 | Int(bytes[start + 34 + $1]) << (8 * $1) }
            return Entry(
                vendor: vendor.trimmingCharacters(in: .whitespaces),
                product: product.trimmingCharacters(in: .whitespaces), offset: offset, submissions: submissions)
        }
    }

    /// Finds the offset for a drive by its product name. If entries for the
    /// product disagree, prefers entries with the drive's vendor or one of its
    /// aliases, and then the entry with the most submissions.
    public func entry(vendor: String, product: String) -> Entry? {
        let product = product.trimmingCharacters(in: .whitespaces).uppercased()
        let candidates = entries.filter { $0.product.uppercased() == product }
        let vendor = vendor.trimmingCharacters(in: .whitespaces).uppercased()
        let names = Set([vendor] + (Self.vendorAliases[vendor] ?? []))
        let sameVendor = candidates.filter { names.contains($0.vendor.uppercased()) }
        let preferred = sameVendor.isEmpty ? candidates : sameVendor
        return preferred.max { $0.submissions < $1.submissions }
    }

    /// Downloads the list.
    public static func download(client: WebClient = .shared) async throws -> DriveOffsetList {
        guard let data = try await client.data(from: url) else {
            throw OnlineLookupError.httpStatus(404, url)
        }
        return try DriveOffsetList(bytes: [UInt8](data))
    }
}

public enum DriveOffsetListError: Error, Equatable {
    case malformed
}
