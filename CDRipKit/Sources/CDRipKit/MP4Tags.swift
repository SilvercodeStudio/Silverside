import Foundation

/// Writes the tags of an MP4 file (ALAC or AAC in .m4a): iTunes atoms in
/// `moov/udta/meta/ilst`, and freeform `----` atoms for the fields that iTunes has none for.
///
/// Apple's encoder puts `moov` before the audio (`mdat`), and the chunk offsets in each
/// `stco` (or `co64`) atom are positions in the file. New tags make `moov` larger and move
/// the audio, so the writer moves every chunk offset by the same amount. Freeform items
/// that the encoder wrote (such as `iTunSMPB`, for gapless playback) are kept.
public enum MP4Tags {
    /// Vorbis comment keys and their iTunes atoms.
    static let textAtoms: [String: String] = [
        "TITLE": "©nam", "ARTIST": "©ART", "ALBUMARTIST": "aART", "ALBUM": "©alb", "DATE": "©day",
        "GENRE": "©gen",
    ]

    /// Vorbis comment keys and the names of their freeform atoms, as MusicBrainz Picard writes them.
    static let freeformNames: [String: String] = [
        "DISCSUBTITLE": "DISCSUBTITLE", "ORIGINALDATE": "ORIGINALDATE", "ISRC": "ISRC", "BARCODE": "BARCODE",
        "COMPILATION": "COMPILATION",
        "LABEL": "LABEL", "CATALOGNUMBER": "CATALOGNUMBER", "RELEASECOUNTRY": "MusicBrainz Album Release Country",
        "MUSICBRAINZ_ALBUMID": "MusicBrainz Album Id", "MUSICBRAINZ_RELEASEGROUPID": "MusicBrainz Release Group Id",
        "MUSICBRAINZ_TRACKID": "MusicBrainz Track Id", "MUSICBRAINZ_ALBUMARTISTID": "MusicBrainz Album Artist Id",
        "MUSICBRAINZ_ARTISTID": "MusicBrainz Artist Id",
    ]

    /// Replaces the file's tags.
    public static func write(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let top = try atoms(in: data, data.startIndex..<data.endIndex)
        guard let moov = top.first(where: { $0.type == "moov" }), let mdat = top.first(where: { $0.type == "mdat" })
        else { throw MP4Error.malformed }

        // The freeform items that the encoder wrote, and that CDRip does not write.
        let ours = Set(freeformNames.values)
        let keptItems = try existingItems(in: data, moov: moov).filter { item in
            guard let name = try? freeformName(of: item, in: data) else { return false }
            return !ours.contains(name)
        }
        let ilst = atom("ilst", keptItems.map { Data(data[$0.range]) } + items(comments, cover: cover))

        // The new layout: the same atoms, with no free space before the audio, and the new moov.
        let order = top.filter { !(["free", "skip"].contains($0.type) && $0.range.lowerBound < mdat.range.lowerBound) }
        func layout(shift: Int) throws -> [Data] {
            try order.map {
                $0.type == "moov" ? try newMoov(data, moov, ilst: ilst, shift: shift) : Data(data[$0.range])
            }
        }
        let draft = try layout(shift: 0)
        let newMdatStart = zip(order, draft).prefix { $0.0.type != "mdat" }.reduce(0) { $0 + $1.1.count }
        let shift = newMdatStart - (mdat.range.lowerBound - data.startIndex)
        let output = shift == 0 ? draft : try layout(shift: shift)
        try output.reduce(Data(), +).write(to: url, options: .atomic)
    }

    /// The file's tags, as Vorbis comment keys and values, and the cover's data.
    public static func read(_ url: URL) throws -> (comments: [(key: String, value: String)], cover: Data?) {
        let data = try Data(contentsOf: url)
        let top = try atoms(in: data, data.startIndex..<data.endIndex)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw MP4Error.malformed }
        let textKeys = Dictionary(uniqueKeysWithValues: textAtoms.map { ($0.value, $0.key) })
        let freeformKeys = Dictionary(uniqueKeysWithValues: freeformNames.map { ($0.value, $0.key) })
        var comments = [(key: String, value: String)]()
        var cover: Data?
        for item in try existingItems(in: data, moov: moov) {
            let children = try atoms(in: data, item.body)
            // A data atom starts with its type and locale, 8 bytes; one without them is skipped.
            let values = children.filter { $0.type == "data" && $0.body.count >= 8 }.map {
                data[($0.body.lowerBound + 8)..<$0.body.upperBound]
            }
            switch item.type {
            case "trkn", "disk":
                guard let value = values.first, value.count >= 6 else { continue }
                let bytes = [UInt8](value)
                let number = Int(bytes[2]) << 8 | Int(bytes[3])
                let total = Int(bytes[4]) << 8 | Int(bytes[5])
                let (key, totalKey) = item.type == "trkn" ? ("TRACKNUMBER", "TRACKTOTAL") : ("DISCNUMBER", "DISCTOTAL")
                comments += [(key, String(number)), (totalKey, String(total))]
            case "covr":
                cover = values.first.map { Data($0) }
            case "----":
                guard let name = try freeformName(of: item, in: data), let key = freeformKeys[name] else { continue }
                comments += values.map { (key, String(decoding: $0, as: UTF8.self)) }
            default:
                guard let key = textKeys[item.type] else { continue }
                comments += values.map { (key, String(decoding: $0, as: UTF8.self)) }
            }
        }
        return (comments, cover)
    }

    // MARK: - Atoms

    struct Atom {
        var type: String
        /// The whole atom, header included.
        var range: Range<Int>
        /// The contents, after the header.
        var body: Range<Int>
    }

    static func atoms(in data: Data, _ range: Range<Int>) throws -> [Atom] {
        var result = [Atom]()
        var index = range.lowerBound
        while index + 8 <= range.upperBound {
            var size = Int(uint32(data, index))
            let type = String(decoding: data[(index + 4)..<(index + 8)], as: UTF8.self).replacingOccurrences(
                of: "\u{FFFD}", with: "©")
            var header = 8
            if size == 1 {
                guard index + 16 <= range.upperBound else { throw MP4Error.malformed }
                size = Int(uint32(data, index + 8)) << 32 | Int(uint32(data, index + 12))
                header = 16
            } else if size == 0 {
                size = range.upperBound - index
            }
            guard size >= header, index + size <= range.upperBound else { throw MP4Error.malformed }
            result.append(Atom(type: type, range: index..<(index + size), body: (index + header)..<(index + size)))
            index += size
        }
        return result
    }

    /// The items of moov/udta/meta/ilst, if the file has them.
    static func existingItems(in data: Data, moov: Atom) throws -> [Atom] {
        guard let udta = try atoms(in: data, moov.body).first(where: { $0.type == "udta" }),
            let meta = try atoms(in: data, udta.body).first(where: { $0.type == "meta" })
        else { return [] }
        // meta is a full atom: its version and flags come before its children.
        guard meta.body.count >= 4 else { throw MP4Error.malformed }
        let metaChildren = (meta.body.lowerBound + 4)..<meta.body.upperBound
        guard let ilst = try atoms(in: data, metaChildren).first(where: { $0.type == "ilst" }) else { return [] }
        return try atoms(in: data, ilst.body)
    }

    static func freeformName(of item: Atom, in data: Data) throws -> String? {
        guard item.type == "----",
            let name = try atoms(in: data, item.body).first(where: { $0.type == "name" }), name.body.count >= 4
        else { return nil }
        return String(decoding: data[(name.body.lowerBound + 4)..<name.body.upperBound], as: UTF8.self)
    }

    /// moov with a new udta (ilst in it, and any other udta contents kept), and every
    /// chunk offset moved by `shift`.
    static func newMoov(_ data: Data, _ moov: Atom, ilst: Data, shift: Int) throws -> Data {
        var children = [Data]()
        var hasUserData = false
        for child in try atoms(in: data, moov.body) {
            if child.type == "udta" {
                hasUserData = true
                let others = try atoms(in: data, child.body).filter { $0.type != "meta" }.map { Data(data[$0.range]) }
                children.append(atom("udta", [meta(ilst)] + others))
            } else if child.type == "trak" {
                children.append(try shifted(data, child, by: shift))
            } else {
                children.append(Data(data[child.range]))
            }
        }
        if !hasUserData { children.append(atom("udta", [meta(ilst)])) }
        return atom("moov", children)
    }

    /// A copy of an atom, with the offsets in its stco and co64 atoms moved by `shift`.
    static func shifted(_ data: Data, _ container: Atom, by shift: Int) throws -> Data {
        var copy = Data(data[container.range])
        let base = container.range.lowerBound
        func visit(_ range: Range<Int>) throws {
            for child in try atoms(in: data, range) {
                switch child.type {
                case "trak", "mdia", "minf", "stbl":
                    try visit(child.body)
                case "stco", "co64":
                    let wide = child.type == "co64"
                    guard child.body.count >= 8 else { throw MP4Error.malformed }
                    let count = Int(uint32(data, child.body.lowerBound + 4))
                    guard child.body.count >= 8 + count * (wide ? 8 : 4) else { throw MP4Error.malformed }
                    var at = child.body.lowerBound + 8
                    for _ in 0..<count {
                        if wide {
                            let value = (Int(uint32(data, at)) << 32 | Int(uint32(data, at + 4))) + shift
                            putUInt32(&copy, at - base, UInt32(truncatingIfNeeded: value >> 32))
                            putUInt32(&copy, at - base + 4, UInt32(truncatingIfNeeded: value))
                            at += 8
                        } else {
                            let value = Int(uint32(data, at)) + shift
                            guard (0...Int(UInt32.max)).contains(value) else { throw MP4Error.tooLarge }
                            putUInt32(&copy, at - base, UInt32(value))
                            at += 4
                        }
                    }
                default:
                    break
                }
            }
        }
        try visit(container.body)
        return copy
    }

    // MARK: - Writing items

    static func items(_ comments: [(key: String, value: String)], cover: EmbeddedCover?) -> [Data] {
        var items = [Data]()
        var values = [String: [String]]()
        var order = [String]()
        for (key, value) in comments {
            if values[key] == nil { order.append(key) }
            values[key, default: []].append(value)
        }
        for key in order {
            let list = values[key]!
            if let type = textAtoms[key] {
                items.append(atom(type, list.map { dataAtom(1, Data($0.utf8)) }))
            } else if let name = freeformNames[key] {
                let mean = atom("mean", [Data(count: 4) + Data("com.apple.iTunes".utf8)])
                let nameAtom = atom("name", [Data(count: 4) + Data(name.utf8)])
                items.append(atom("----", [mean, nameAtom] + list.map { dataAtom(1, Data($0.utf8)) }))
            }
        }
        func pair(_ number: String?, _ total: String?, trailing: Int) -> Data? {
            guard let number = number.flatMap({ Int($0) }) else { return nil }
            let total = total.flatMap { Int($0) } ?? 0
            return Data([
                0, 0, UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF), UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF),
            ])
                + Data(count: trailing)
        }
        if let track = pair(values["TRACKNUMBER"]?.first, values["TRACKTOTAL"]?.first, trailing: 2) {
            items.append(atom("trkn", [dataAtom(0, track)]))
        }
        if let disc = pair(values["DISCNUMBER"]?.first, values["DISCTOTAL"]?.first, trailing: 0) {
            items.append(atom("disk", [dataAtom(0, disc)]))
        }
        items.append(atom("©too", [dataAtom(1, Data(FLACTags.vendor.utf8))]))
        if let cover, let fileExtension = cover.image.fileExtension {
            items.append(atom("covr", [dataAtom(fileExtension == "png" ? 14 : 13, cover.image.data)]))
        }
        return items
    }

    /// A `data` atom: its type (1 for UTF-8 text, 0 for numbers, 13 for JPEG, 14 for PNG), no locale, and the value.
    static func dataAtom(_ type: UInt32, _ value: Data) -> Data {
        var header = Data()
        appendUInt32(&header, type)
        appendUInt32(&header, 0)
        return atom("data", [header + value])
    }

    /// meta, a full atom: version and flags, the iTunes handler, then ilst.
    static func meta(_ ilst: Data) -> Data {
        var handler = Data(count: 8)
        handler += Data("mdirappl".utf8)
        handler += Data(count: 9)
        return atom("meta", [Data(count: 4), atom("hdlr", [handler]), ilst])
    }

    static func atom(_ type: String, _ contents: [Data]) -> Data {
        let body = contents.reduce(Data(), +)
        var result = Data()
        appendUInt32(&result, UInt32(8 + body.count))
        // "©" is the single byte 0xA9 in atom types.
        result += Data(type.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        return result + body
    }

    static func uint32(_ data: Data, _ index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[index + $1]) }
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data += Data((0..<4).reversed().map { UInt8(value >> (8 * UInt32($0)) & 0xFF) })
    }

    static func putUInt32(_ data: inout Data, _ index: Int, _ value: UInt32) {
        let start = data.startIndex + index
        for offset in 0..<4 { data[start + offset] = UInt8(value >> (8 * UInt32(3 - offset)) & 0xFF) }
    }
}

public enum MP4Error: Error, Equatable, CustomStringConvertible {
    case malformed
    case tooLarge

    public var description: String {
        switch self {
        case .malformed: "The file is not an MP4 file that Silverside can read."
        case .tooLarge: "The file is too large for its 32-bit chunk offsets."
        }
    }
}
