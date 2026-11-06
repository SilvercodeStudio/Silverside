import Foundation

extension DVDNavigation {
    /// Recognize the bounded, paired AMG title-table mapping seen on Spectrum.
    /// A missing AOB alone is never evidence of a video link. Require agreement
    /// between both manager tables, the ATS link address and its title records.
    /// Field descriptions: dvd-audio.sourceforge.io/spec/audio_ts.shtml.
    public static func videoReferences(manager: Data, ifo: Data, titleSet: Int) throws -> [Int: DVDVideoReference] {
        let audio = Bytes(ifo)
        let amg = Bytes(manager)
        guard try amg.signature() == "DVDAUDIO-AMG", try audio.signature() == "DVDAUDIO-ATS" else {
            throw DVDError("Invalid DVD navigation identifiers.")
        }
        let linkAddress = try audio.number(192, 4)
        guard linkAddress != 0 else { return [:] }
        func table(_ offset: Int) throws -> [Int] {
            let start = try amg.number(offset, 4) * 2048
            guard start >= 2048 else { throw DVDError("Missing AMG title table for a possible video reference.") }
            let count = try amg.number(start, 2)
            let end = try start + amg.number(start + 2, 2) + 1
            guard count > 0, count <= 255, start + 4 + count * 14 <= end, end <= manager.count else {
                throw DVDError("Truncated or oversized AMG title table.")
            }
            return (0..<count).map { start + 4 + $0 * 14 }
        }
        let general = try table(196)
        let audioOnly = try table(200)
        guard general.count == audioOnly.count else {
            throw DVDError("Unrecognized AMG video-reference mapping.")
        }
        let titles = try audio.number(204, 4) * 2048
        let count = try audio.number(titles, 2)
        guard titles >= 2048, (1...255).contains(count) else { throw DVDError("Invalid ATS title table.") }
        var references = [Int: DVDVideoReference]()
        for (entry, paired) in zip(audioOnly, general) {
            guard try amg.number(entry, 1) & 0x80 != 0, try amg.number(entry + 8, 1) == titleSet else { continue }
            let kind = try amg.number(paired, 1) & 0xf0
            guard kind == 0 || kind == 0x40,
                try amg.number(paired + 10, 4) == linkAddress
            else { continue }
            let title = try amg.number(entry + 9, 1)
            let videoSet = try amg.number(paired + 8, 1)
            let videoTitle = try amg.number(paired + 9, 1)
            guard (1...count).contains(title), (1...99).contains(videoSet), (1...99).contains(videoTitle),
                references[title] == nil
            else { throw DVDError("Invalid or duplicate AMG video reference.") }
            let record = try titles + audio.number(titles + 8 + (title - 1) * 8 + 4, 4)
            guard try amg.number(entry + 1, 1) == amg.number(paired + 1, 1),
                try amg.number(entry + 1, 1) == audio.number(record + 2, 1),
                try amg.number(entry + 4, 4) == amg.number(paired + 4, 4),
                try amg.number(entry + 4, 4) == audio.number(record + 4, 4)
            else { throw DVDError("AMG video reference disagrees with ATS navigation.") }
            references[title] = DVDVideoReference(titleSet: videoSet, title: videoTitle)
        }
        guard references.isEmpty || references.count == count else {
            throw DVDError("Only some ATS titles have a verified video reference.")
        }
        return references
    }
}
