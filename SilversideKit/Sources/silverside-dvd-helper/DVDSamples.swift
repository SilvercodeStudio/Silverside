import Foundation
import SilversideKit

enum DVDSamples {
    /// Collect bounded samples even for unsupported timelines, whose individual
    /// sector extents the navigation reader has still checked. Shared extents
    /// are read once. A failed sample is reported, never probed as plaintext.
    static func collect(
        _ inventory: inout DVDInventory, work: URL,
        read: (Int, Int, Int, String) throws -> Void
    ) {
        var cached = [String: URL]()
        var reads = 0
        for index in inventory.presentations.indices {
            let presentation = inventory.presentations[index]
            guard presentation.videoReference == nil else { continue }
            var observations = [DVDTrackFormat]()
            for track in presentation.tracks {
                let count = min(512, track.lastSector - track.firstSector + 1)
                let key = "\(presentation.titleSet):\(track.firstSector):\(count)"
                let output = work.appendingPathComponent(presentation.sampleFile(track: track.number))
                var observation = DVDTrackFormat(number: track.number)
                do {
                    if let existing = cached[key] {
                        try FileManager.default.copyItem(at: existing, to: output)
                    } else {
                        guard reads < 512 else { throw DVDError("Inventory exceeds 512 unique track samples.") }
                        reads += 1
                        try read(presentation.titleSet, track.firstSector, count, output.path)
                        cached[key] = output
                    }
                } catch {
                    observation.unsupportedReason = "Sample read failed: \(error)"
                }
                observations.append(observation)
            }
            inventory.presentations[index].trackFormats = observations
        }
    }

    static func requireAudio(_ inventory: DVDInventory, titleSet: Int) throws {
        if let issue = inventory.titleSetIssues?.first(where: { $0.titleSet == titleSet }) {
            throw DVDError(issue.reason)
        }
        let programs = inventory.presentations.filter { $0.titleSet == titleSet }
        guard !programs.isEmpty, programs.allSatisfy({ $0.videoReference == nil }) else {
            throw DVDError("Title set \(titleSet) is not an available AOB audio source.")
        }
    }
}
