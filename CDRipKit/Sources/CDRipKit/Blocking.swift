import Foundation

/// A value handed to one other thread and back, with no check that it is safe to share:
/// `blocking(_:)` gives it to one thread at a time, and nothing else uses it meanwhile.
final class Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Threads for work that blocks for a long time: drive reads, and encoding.
private let blockingQueue = DispatchQueue(label: "CDRip.blocking", qos: .userInitiated, attributes: .concurrent)

/// Runs `work`, which blocks for a long time, on a thread of its own, and waits for it.
///
/// A task that did such work itself would hold a thread of Swift's cooperative pool for
/// the length of a rip, and the pool has one thread for each core. The values that `work`
/// captures are used by that one thread until it returns, and by the caller after, so they
/// need not be Sendable. The result crosses back to the caller, so it must be.
func blocking<T: Sendable>(_ work: @escaping () throws -> T) async throws -> T {
    let boxed = Unchecked(work)
    return try await withCheckedThrowingContinuation { continuation in
        blockingQueue.async {
            continuation.resume(with: Result { try boxed.value() })
        }
    }
}
