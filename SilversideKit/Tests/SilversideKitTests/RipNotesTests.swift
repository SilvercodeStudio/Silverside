import Foundation
import Testing

@testable import SilversideKit

/// The user's notes on a rip, kept in its reports and the history.
struct RipNotesTests {
    @Test func savesNotesInTheReportsAndTheHistory() async throws {
        let (result, _, _, root) = try await DiscRipTests().rip()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = result.folder.appending(path: "disc.json")
        let history = RipHistory(directory: root.appending(path: "History"))
        let before = try Data(contentsOf: file)
        try RipReport.saveNotes(
            "  Stealth HDCD: no logo anywhere.\n", of: result.report, at: file, hasAudio: true, history: history)
        let report = try RipReport.read(from: file)
        #expect(report.notes == "Stealth HDCD: no logo anywhere.")
        #expect(report.markdown.contains("## Notes\n\nStealth HDCD: no logo anywhere.\n"))
        #expect(history.entries().values.first?.report.notes == "Stealth HDCD: no logo anywhere.")
        // Every other key stays.
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["notes"] = nil
        let original = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        #expect(Set(object.keys) == Set(original.keys))

        // Empty notes are none; a report that is gone changes the history only.
        try RipReport.saveNotes(" ", of: report, at: file, hasAudio: true, history: history)
        #expect(try RipReport.read(from: file).notes == nil)
        let gone = root.appending(path: "gone/disc.json")
        try RipReport.saveNotes("Moved to the NAS", of: report, at: gone, hasAudio: false, history: history)
        #expect(history.entries().values.contains { $0.report.notes == "Moved to the NAS" && $0.url == gone })
    }
}
