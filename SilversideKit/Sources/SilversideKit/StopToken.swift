import Synchronization

/// A request to stop a rip or a repair, safe to set from any thread. The engine checks it
/// between chunks of a read, between rounds of re-reads, and between tracks, and throws
/// `CancellationError` once it is set. A drive read that is under way finishes first.
///
/// `DiscRip.run()` and `RipRepair.run()` also stop when their task is cancelled.
public final class StopToken: Sendable {
    private let flag = Atomic<Bool>(false)

    public init() {}

    public var isStopped: Bool { flag.load(ordering: .relaxed) }

    public func stop() {
        flag.store(true, ordering: .relaxed)
    }

    /// Throws `CancellationError` if the token is stopped.
    public func check() throws {
        if isStopped { throw CancellationError() }
    }
}
