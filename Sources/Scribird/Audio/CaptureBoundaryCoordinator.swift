import Foundation

/// One capture cut orders original-audio writes and analyzer markers across both sources.
final class CaptureBoundaryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.scribird.capture-boundary")

    /// Keeps a captured buffer's original write and analyzer delivery on the same side of a cut.
    func submit<T>(_ operation: () throws -> T) rethrows -> T { try lock.withLock(operation) }

    /// A boundary may wait for an in-flight capture callback without blocking the main actor.
    func rotate(_ operation: @escaping @Sendable () -> [URL]) async -> [URL] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: lock.withLock(operation))
            }
        }
    }
}
