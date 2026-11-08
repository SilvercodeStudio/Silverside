import Foundation

/// Progress is about the operation actually taking place, not a guessed overall
/// percentage. Only the source read has a measured byte/sector denominator.
public enum DVDProgress: Sendable, Equatable {
    case inspecting
    case reading(program: String, sectors: Int64, total: Int64)
    case decoding(program: String, firstTrack: Int, lastTrack: Int)
    case checking(program: String, track: Int, total: Int)
    case published(program: String)
    case finished
}

/// App-facing entry points. Blocking drive/library/process work stays off the
/// cooperative executor; cancellation reaches the helper and decoder processes.
public enum DVDWorkflow {
    public static func inspect(source: String, stop: StopToken = StopToken()) async throws -> DVDInventory {
        try await withTaskCancellationHandler {
            try await blocking {
                try stop.check()
                let tools = try DVDTools()
                let work = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "silverside-dvd-info-\(UUID())")
                try FileManager.default.createDirectory(
                    at: work, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: work) }
                return try tools.inventory(source: source, work: work, stop: stop)
            }
        } onCancel: {
            stop.stop()
        }
    }

    public static func rip(
        source: String, output: URL, title: String, metadata: DVDMetadata,
        stop: StopToken = StopToken(), progress: @escaping @Sendable (DVDProgress) -> Void = { _ in }
    ) async throws -> DVDRipReport {
        try await withTaskCancellationHandler {
            try await blocking {
                try stop.check()
                return try DVDExtraction.rip(
                    source: source, output: output, tools: DVDTools(), title: title,
                    metadata: metadata, stop: stop, events: progress)
            }
        } onCancel: {
            stop.stop()
        }
    }
}
