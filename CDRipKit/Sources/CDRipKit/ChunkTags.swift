import Foundation

/// Writes the tags of AIFF and WAV files, which keep them in chunks after the audio.
///
/// Both get an ID3v2.4 tag in a chunk (`ID3 ` in AIFF, as Apple Music writes it; `id3 ` in
/// WAV, as MusicBrainz Picard, foobar2000, and Mp3tag read it), with the same frames as
/// MP3. WAV also gets a `LIST`/`INFO` chunk with the basic fields, for older tools. Tag
/// chunks that the file has are replaced; the audio is not touched.
public enum ChunkTags {
    public static func writeAIFF(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, to url: URL) throws
    {
        try rewrite(url, bigEndian: true, form: "FORM", removing: ["ID3 "]) {
            [("ID3 ", ID3Tags.tag(comments, cover: cover))]
        }
    }

    public static func writeWAV(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, to url: URL) throws {
        try rewrite(url, bigEndian: false, form: "RIFF", removing: ["LIST", "id3 ", "ID3 "]) {
            [("LIST", info(comments)), ("id3 ", ID3Tags.tag(comments, cover: cover))]
        }
    }

    /// The `INFO` list: each field as a chunk of text that ends in a null.
    static func info(_ comments: [(key: String, value: String)]) -> Data {
        let fields: [(String, String)] = [
            ("INAM", "TITLE"), ("IART", "ARTIST"), ("IPRD", "ALBUM"), ("ITRK", "TRACKNUMBER"), ("ICRD", "DATE"),
            ("IGNR", "GENRE"), ("ISRC", "ISRC"),
        ]
        var data = Data("INFO".utf8)
        for (id, key) in fields {
            guard let value = comments.first(where: { $0.key == key })?.value else { continue }
            data += chunk(id, Data(value.utf8) + Data([0]), bigEndian: false)
        }
        data += chunk("ISFT", Data(FLACTags.vendor.utf8) + Data([0]), bigEndian: false)
        return data
    }

    /// Takes the file apart into chunks, leaves out the ones named in `removing` (a LIST
    /// only if it is an INFO list), adds the new ones at the end, and writes the file again.
    private static func rewrite(
        _ url: URL, bigEndian: Bool, form: String, removing: Set<String>, new: () -> [(String, Data)]
    ) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 12, bytes[0..<4].elementsEqual(form.utf8) else { throw ChunkTagsError.malformed }
        func uint32(_ at: Int) -> Int {
            (0..<4).reduce(0) { bigEndian ? $0 << 8 | Int(bytes[at + $1]) : $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        var output = Data(bytes[8..<12])  // the form type: "AIFF", "AIFC", or "WAVE"
        var at = 12
        while at + 8 <= bytes.count {
            let id = String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
            let size = uint32(at + 4)
            let end = min(at + 8 + size + size % 2, bytes.count)
            let isInfoList =
                id == "LIST" && at + 12 <= bytes.count && bytes[(at + 8)..<(at + 12)].elementsEqual("INFO".utf8)
            if !removing.contains(id) || (id == "LIST" && !isInfoList) {
                output += bytes[at..<end]
            }
            at = end
        }
        for (id, body) in new() { output += chunk(id, body, bigEndian: bigEndian) }
        var file = Data(form.utf8)
        file += sizeBytes(output.count, bigEndian: bigEndian)
        file += output
        try file.write(to: url, options: .atomic)
    }

    /// A chunk: its ID, its size, its body, and a pad byte if the size is odd.
    static func chunk(_ id: String, _ body: Data, bigEndian: Bool) -> Data {
        Data(id.utf8) + sizeBytes(body.count, bigEndian: bigEndian) + body + (body.count % 2 == 1 ? Data([0]) : Data())
    }

    static func sizeBytes(_ value: Int, bigEndian: Bool) -> Data {
        let bytes = (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) }
        return Data(bigEndian ? bytes.reversed() : bytes)
    }
}

public enum ChunkTagsError: Error, Equatable, CustomStringConvertible {
    case malformed

    public var description: String { "The file is not an AIFF or WAV file that Silverside can read." }
}
