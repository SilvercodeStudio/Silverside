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
        "GENRE": "©gen", "COMPOSER": "©wrt", "ARTISTSORT": "soar", "ALBUMARTISTSORT": "soaa",
    ]

    /// Vorbis comment keys and the names of their freeform atoms, as MusicBrainz Picard writes them.
    static let freeformNames: [String: String] = [
        "DISCSUBTITLE": "DISCSUBTITLE", "ORIGINALDATE": "ORIGINALDATE", "ISRC": "ISRC", "BARCODE": "BARCODE",
        "COMPILATION": "COMPILATION", "LYRICIST": "LYRICIST",
        "LABEL": "LABEL", "CATALOGNUMBER": "CATALOGNUMBER", "RELEASECOUNTRY": "MusicBrainz Album Release Country",
        "MUSICBRAINZ_ALBUMID": "MusicBrainz Album Id", "MUSICBRAINZ_RELEASEGROUPID": "MusicBrainz Release Group Id",
        "MUSICBRAINZ_TRACKID": "MusicBrainz Track Id", "MUSICBRAINZ_ALBUMARTISTID": "MusicBrainz Album Artist Id",
        "MUSICBRAINZ_ARTISTID": "MusicBrainz Artist Id",
        "REPLAYGAIN_TRACK_GAIN": "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK": "REPLAYGAIN_TRACK_PEAK",
        "REPLAYGAIN_ALBUM_GAIN": "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK": "REPLAYGAIN_ALBUM_PEAK",
        "REPLAYGAIN_REFERENCE_LOUDNESS": "REPLAYGAIN_REFERENCE_LOUDNESS", "HDCD": "HDCD",
        "REPLAYGAIN_TRACK_RANGE": "REPLAYGAIN_TRACK_RANGE", "REPLAYGAIN_ALBUM_RANGE": "REPLAYGAIN_ALBUM_RANGE",
        "DYNAMIC RANGE": "DYNAMIC RANGE", "ALBUM DYNAMIC RANGE": "ALBUM DYNAMIC RANGE",
        "PRE_EMPHASIS": "PRE_EMPHASIS", "DE_EMPHASIZED": "DE_EMPHASIZED", "MEDIA": "MEDIA",
    ]

    /// Replaces the file's tags.
    public static func write(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let top = try atoms(in: data, data.startIndex..<data.endIndex)
        guard let moov = top.first(where: { $0.type == "moov" }), let mdat = top.first(where: { $0.type == "mdat" })
        else { throw MP4Error.malformed }

        // The freeform items that the encoder wrote, and that Silverside does not write.
        let ours = Set(freeformNames.values)
        let keptItems = try existingItems(in: data, moov: moov).filter { item in
            guard let name = try? freeformName(of: item, in: data) else { return false }
            return !ours.contains(name)
        }
        let ilst = atom("ilst", keptItems.map { Data(data[$0.range]) } + items(comments, cover: cover))
        try rewritten(data, top: top, moov: moov, mdat: mdat, ilst: ilst).write(to: url, options: .atomic)
    }

    /// The file's contents with `cover` as its cover (`covr`), in place of any it has. Every
    /// other item stays as it is, whoever wrote it, and so does the rest of `meta` (its
    /// handler, and atoms such as `keys`, `ID32`, or `free`); the audio and the other atoms are
    /// copied, and only the chunk offsets move with the audio (`AudioPayload` checks them).
    /// A `meta` whose handler is not iTunes's (`mdir`), such as QuickTime's `mdta`, whose items
    /// are named by its `keys`, is refused: a `covr` item means nothing there.
    public static func replacingCover(with cover: EmbeddedCover, in data: Data) throws -> Data {
        try updating(data, removing: [], adding: [], cover: cover)
    }

    /// The file's contents with its items for `keys` (Vorbis comment keys in capitals, as
    /// `keys(of:in:)` names an item) taken out, `comments` added as items, and `cover` as its
    /// cover (nil keeps it, unless `removingCover`). Every other item stays, whoever wrote it,
    /// and so does the rest of meta, as for `replacingCover`. COMPILATION goes in `cpil`, as
    /// iTunes and Picard keep it. No `©too`: the file's encoder stays.
    public static func updating(
        _ data: Data, removing keys: Set<String>, adding comments: [(key: String, value: String)],
        cover: EmbeddedCover?, removingCover: Bool = false
    ) throws -> Data {
        let top = try atoms(in: data, data.startIndex..<data.endIndex)
        guard let moov = top.first(where: { $0.type == "moov" }), let mdat = top.first(where: { $0.type == "mdat" })
        else { throw MP4Error.malformed }
        if let cover, cover.image.fileExtension == nil { throw CoverArtError.unknownFormat }
        if let handler = try metaHandler(in: data, moov: moov), handler != "mdir" { throw MP4Error.otherTags(handler) }
        let kept = try existingItems(in: data, moov: moov).filter { item in
            if item.type == "covr" { return cover == nil && !removingCover }
            return try !Self.keys(of: item, in: data).contains(where: keys.contains)
        }.map { Data(data[$0.range]) }
        var added = items(comments.filter { $0.key != "COMPILATION" }, cover: cover, vendor: false)
        if comments.contains(where: { $0.key == "COMPILATION" && $0.value == "1" }) {
            added.append(atom("cpil", [dataAtom(21, Data([1]))]))
        }
        return try rewritten(
            data, top: top, moov: moov, mdat: mdat, ilst: atom("ilst", kept + added), keepingMeta: true)
    }

    /// True if the writers keep the Vorbis comment key `key` in an item.
    static func writes(_ key: String) -> Bool {
        textAtoms[key] != nil || freeformNames[key] != nil
            || ["TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL"].contains(key)
    }

    /// Picard's freeform names for tags that Silverside does not write, by the Vorbis comment key.
    static let otherFreeformKeys: [String: String] = [
        "MusicBrainz Album Type": "RELEASETYPE", "MusicBrainz Album Status": "RELEASESTATUS",
        "MusicBrainz Release Track Id": "MUSICBRAINZ_RELEASETRACKID", "MusicBrainz Disc Id": "MUSICBRAINZ_DISCID",
        "MusicBrainz Work Id": "MUSICBRAINZ_WORKID", "MusicBrainz Album Comment": "MUSICBRAINZ_ALBUMCOMMENT",
        "Acoustid Id": "ACOUSTID_ID", "ASIN": "ASIN", "SCRIPT": "SCRIPT", "LANGUAGE": "LANGUAGE",
    ]

    /// The Vorbis comment keys, in capitals, that an item holds: trkn holds TRACKNUMBER and
    /// TRACKTOTAL, a freeform item its name's key, another item its type's.
    static func keys(of item: Atom, in data: Data) throws -> [String] {
        let textKeys = Dictionary(uniqueKeysWithValues: textAtoms.map { ($0.value, $0.key) })
        let freeformKeys = Dictionary(uniqueKeysWithValues: freeformNames.map { ($0.value, $0.key) })
        switch item.type {
        case "trkn": return ["TRACKNUMBER", "TRACKTOTAL"]
        case "disk": return ["DISCNUMBER", "DISCTOTAL"]
        case "----":
            guard let name = try freeformName(of: item, in: data) else { return [] }
            return [(freeformKeys[name] ?? otherFreeformKeys[name] ?? name).uppercased()]
        default: return [(textKeys[item.type] ?? otherAtoms[item.type] ?? item.type).uppercased()]
        }
    }

    /// The handler type of moov/udta/meta ("mdir" for iTunes's tags), or nil if there is no meta.
    static func metaHandler(in data: Data, moov: Atom) throws -> String? {
        guard let udta = try atoms(in: data, moov.body).first(where: { $0.type == "udta" }),
            let meta = try atoms(in: data, udta.body).first(where: { $0.type == "meta" })
        else { return nil }
        guard meta.body.count >= 4 else { throw MP4Error.malformed }
        let children = try atoms(in: data, (meta.body.lowerBound + 4)..<meta.body.upperBound)
        guard let hdlr = children.first(where: { $0.type == "hdlr" }), hdlr.body.count >= 12 else { return "" }
        return String(decoding: data[(hdlr.body.lowerBound + 8)..<(hdlr.body.lowerBound + 12)], as: UTF8.self)
    }

    /// The file with `ilst` in place of its items: the same top-level atoms, with no free space
    /// before the audio, a new moov, and every chunk offset moved by as much as the audio moved.
    /// With `keepingMeta`, the rest of an existing meta stays (`newMoov`).
    static func rewritten(
        _ data: Data, top: [Atom], moov: Atom, mdat: Atom, ilst: Data, keepingMeta: Bool = false
    ) throws -> Data {
        let order = top.filter { !(["free", "skip"].contains($0.type) && $0.range.lowerBound < mdat.range.lowerBound) }
        func layout(shift: Int) throws -> [Data] {
            try order.map {
                $0.type == "moov"
                    ? try newMoov(data, moov, ilst: ilst, shift: shift, keepingMeta: keepingMeta)
                    : Data(data[$0.range])
            }
        }
        let draft = try layout(shift: 0)
        let newMdatStart = zip(order, draft).prefix { $0.0.type != "mdat" }.reduce(0) { $0 + $1.1.count }
        let shift = newMdatStart - (mdat.range.lowerBound - data.startIndex)
        let output = shift == 0 ? draft : try layout(shift: shift)
        return output.reduce(Data(), +)
    }

    /// Other programs' items, by the Vorbis comment key a summary shows them as.
    static let otherAtoms: [String: String] = [
        "©cmt": "COMMENT", "©too": "ENCODER", "©grp": "GROUPING", "©lyr": "LYRICS", "cpil": "COMPILATION",
        "tmpo": "BPM", "cprt": "COPYRIGHT", "desc": "DESCRIPTION", "sonm": "TITLESORT", "soal": "ALBUMSORT",
        "soco": "COMPOSERSORT", "©wrk": "WORK", "©mvn": "MOVEMENTNAME", "pgap": "GAPLESS", "rtng": "RATING",
    ]

    /// The file's tags, as Vorbis comment keys and values, and the cover's data. With `every`,
    /// the items Silverside does not write too: other programs' (`otherAtoms`), or an item's own
    /// type ("©xyz") or freeform name; a value that is not text is its number, or its size.
    public static func read(_ url: URL, every: Bool = false) throws -> (
        comments: [(key: String, value: String)], cover: Data?
    ) {
        // Mapped: only the atoms' headers and moov are read, not the audio.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
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
                guard let name = try freeformName(of: item, in: data),
                    let key = freeformKeys[name] ?? (every ? Self.otherFreeformKeys[name] ?? name : nil)
                else { continue }
                comments += values.map { (key, String(decoding: $0, as: UTF8.self)) }
            default:
                if let key = textKeys[item.type] {
                    comments += values.map { (key, String(decoding: $0, as: UTF8.self)) }
                } else if every {
                    let key = otherAtoms[item.type] ?? item.type
                    let typed = children.filter { $0.type == "data" && $0.body.count >= 8 }
                    for atom in typed {
                        let type = uint32(data, atom.body.lowerBound)
                        let value = data[(atom.body.lowerBound + 8)..<atom.body.upperBound]
                        comments.append((key, Self.text(of: value, type: type)))
                    }
                }
            }
        }
        return (comments, cover)
    }

    /// A data atom's value as text: UTF-8 (1), a big-endian integer (0, 21), else its size.
    static func text(of value: Data, type: UInt32) -> String {
        switch type {
        case 1: return String(decoding: value, as: UTF8.self)
        case 0,
            21 where (1...8).contains(value.count):
            return String(value.reduce(0) { $0 << 8 | Int($1) })
        default: return "(\(value.count) bytes)"
        }
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
    /// chunk offset moved by `shift`. Without `keepingMeta`, meta is new (an iTunes handler and
    /// `ilst`); with it, an existing meta keeps its version, flags, and every child but `ilst`,
    /// in their order.
    static func newMoov(_ data: Data, _ moov: Atom, ilst: Data, shift: Int, keepingMeta: Bool = false) throws -> Data {
        var children = [Data]()
        var hasUserData = false
        for child in try atoms(in: data, moov.body) {
            if child.type == "udta" {
                hasUserData = true
                let contents = try atoms(in: data, child.body)
                if keepingMeta, let old = contents.first(where: { $0.type == "meta" }) {
                    guard old.body.count >= 4 else { throw MP4Error.malformed }
                    let header = Data(data[old.body.lowerBound..<(old.body.lowerBound + 4)])
                    let oldChildren = try atoms(in: data, (old.body.lowerBound + 4)..<old.body.upperBound)
                    var metaChildren = oldChildren.map { $0.type == "ilst" ? ilst : Data(data[$0.range]) }
                    if !oldChildren.contains(where: { $0.type == "ilst" }) { metaChildren.append(ilst) }
                    let newMeta = atom("meta", [header] + metaChildren)
                    children.append(atom("udta", contents.map { $0.type == "meta" ? newMeta : Data(data[$0.range]) }))
                    continue
                }
                let others = contents.filter { $0.type != "meta" }.map { Data(data[$0.range]) }
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

    static func items(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, vendor: Bool = true) -> [Data]
    {
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
        if vendor { items.append(atom("©too", [dataAtom(1, Data(FLACTags.vendor.utf8))])) }
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
    /// The tags are not iTunes's: their handler (such as "mdta").
    case otherTags(String)

    public var description: String {
        switch self {
        case .malformed: "The file is not an MP4 file that Silverside can read."
        case .tooLarge: "The file is too large for its 32-bit chunk offsets."
        case .otherTags(let handler):
            "The file's tags are not iTunes tags (their handler is \"\(handler)\"), so Silverside leaves it alone."
        }
    }
}
