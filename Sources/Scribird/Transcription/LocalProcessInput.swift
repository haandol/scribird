import Darwin
import Foundation

/// Writes large local audio requests without occupying the actor that must cancel the child.
final class LocalProcessInput: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.scribird.asr-input")
    private let lock = NSLock()
    private var cancelled = false

    init(handle: FileHandle) { self.handle = handle }

    /// A full pipe is polled on an owned I/O queue, with cancellation checked between bounded waits.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                    let descriptor = handle.fileDescriptor
                    let flags = fcntl(descriptor, F_GETFL)
                    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                          fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count > 0 { offset += count; continue }
                            if count < 0, errno == EINTR { continue }
                            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                                var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                                _ = poll(&pending, 1, 50)
                                continue
                            }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Cancellation never waits for the pipe's reader or the worker actor.
    func cancel() { lock.withLock { cancelled = true } }

    /// Closes after the bounded writer loop has released the descriptor.
    func close() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? handle.close()
                continuation.resume()
            }
        }
    }
}
