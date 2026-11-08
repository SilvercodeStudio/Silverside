import Foundation
import Testing

@testable import SilversideKit

final class DVDProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [DVDProgress]()
    func append(_ value: DVDProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
    var events: [DVDProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct DVDWorkflowTests {
    @Test func stoppedWorkflowDoesNotAccessSourceOrCreateOutput() async throws {
        let root = try DVDTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let stop = StopToken()
        stop.stop()
        await #expect(throws: CancellationError.self) {
            _ = try await DVDWorkflow.inspect(source: "/missing", stop: stop)
        }
        let metadata = DVDMetadata(inventory: try DVDMetadataTests().inventory())
        let destination = root.appendingPathComponent("never-created")
        await #expect(throws: CancellationError.self) {
            _ = try await DVDWorkflow.rip(
                source: "/missing", output: destination, title: "1:1", metadata: metadata, stop: stop)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
