import Foundation

// MARK: - BlockingWork

/// Runs work that blocks its thread — waiting on a child process, reading
/// the address book — off the Swift concurrency pool.
///
/// The pool has one thread per core and never grows, so a blocked thread
/// there stalls everything else scheduled on it (the database actor,
/// polling, sending) until the child returns, which for an AI call can be
/// minutes. GCD threads grow with demand, so a dedicated queue is used.
enum BlockingWork {
    private static let queue = DispatchQueue(label: "weft.blocking", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }
}

// MARK: - OutputCollector

/// Gathers a child process's stdout and stderr as they arrive, so a full
/// pipe can never stall the child, and lets the caller stop waiting when
/// the child has exited even if a helper it left behind still holds the
/// pipe open.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outOpen = true
    private var errOpen = true
    private let closed = DispatchGroup()
    private var handles: [FileHandle] = []

    /// Start reading both handles. `closed` is left when each reaches EOF.
    func attach(stdout: FileHandle, stderr: FileHandle) {
        handles = [stdout, stderr]
        closed.enter()
        closed.enter()
        stdout.readabilityHandler = { [weak self] handle in self?.received(handle.availableData, from: handle, isError: false) }
        stderr.readabilityHandler = { [weak self] handle in self?.received(handle.availableData, from: handle, isError: true) }
    }

    private func received(_ chunk: Data, from handle: FileHandle, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.isEmpty {
            // EOF: stop listening (once).
            handle.readabilityHandler = nil
            if isError, errOpen { errOpen = false; closed.leave() }
            if !isError, outOpen { outOpen = false; closed.leave() }
        } else if isError {
            err.append(chunk)
        } else {
            out.append(chunk)
        }
    }

    /// Wait up to `seconds` for both pipes to close.
    func waitForEOF(seconds: TimeInterval) {
        _ = closed.wait(timeout: .now() + seconds)
    }

    /// Stop reading and return what arrived.
    func finish() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        for handle in handles { handle.readabilityHandler = nil }
        if outOpen { outOpen = false; closed.leave() }
        if errOpen { errOpen = false; closed.leave() }
        return (out, err)
    }
}
