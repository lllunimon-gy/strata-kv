import Foundation

/// Bounded admission plus a serial group-commit queue. Completion means the store's configured
/// durability was reached; use .synchronized/.fullSync when acknowledgments must include a sync.
public final class GroupedWriter: @unchecked Sendable {
    private struct Request {
        let operations: [Mutation]
        let bytes: Int
        let completion: (Result<Void, Error>) -> Void
    }
    private let store: KVStore
    private let queue = DispatchQueue(label: "gy.strata.grouped-writer", qos: .utility)
    private let admission = NSLock()
    private let maximumPendingBytes: Int
    private let maximumPendingRequests: Int
    private let maximumGroupRequests: Int
    private let delay: TimeInterval
    private var pendingBytes = 0
    private var pendingRequests = 0
    private var closed = false
    // Accessed on queue only.
    private var requests: [Request] = []
    private var groupBytes = 0
    private var groupOperations = 0
    private var timer: DispatchWorkItem?

    public init(store: KVStore, maximumDelay: TimeInterval = 0.002, maximumGroupRequests: Int = 64,
                maximumPendingBytes: Int = 32 * 1024 * 1024, maximumPendingRequests: Int = 1024) throws {
        guard maximumDelay.isFinite, maximumDelay >= 0, maximumDelay <= 1,
              maximumGroupRequests > 0, maximumPendingBytes > 0, maximumPendingRequests > 0 else {
            throw StoreError.invalidConfiguration
        }
        self.store = store
        self.delay = maximumDelay
        self.maximumGroupRequests = maximumGroupRequests
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingRequests = maximumPendingRequests
    }
    public func writeBatch(_ operations: [Mutation]) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            submit(operations) { continuation.resume(with: $0) }
        }
    }
    /// Accepted callbacks run on the commit queue; admission failures return on the caller thread.
    /// Keep callbacks short; never synchronously wait for this writer.
    /// Invalid requests fail independently. Once admitted, cancellation does not retract a write.
    public func submit(_ operations: [Mutation], completion: @escaping (Result<Void, Error>) -> Void) {
        let bytes: Int
        do { bytes = try JournalCodec.validatedSize(operations, sequence: UInt64.max) }
        catch { completion(.failure(error)); return }
        admission.lock()
        guard !closed else { admission.unlock(); completion(.failure(StoreError.closed)); return }
        guard pendingRequests < maximumPendingRequests, bytes <= maximumPendingBytes - pendingBytes else {
            admission.unlock(); completion(.failure(StoreError.queueFull)); return
        }
        pendingBytes += bytes
        pendingRequests += 1
        // Enqueue while holding admission so flush/close cannot overtake an accepted request.
        queue.async { self.enqueue(Request(operations: operations, bytes: bytes, completion: completion)) }
        admission.unlock()
    }
    private func enqueue(_ request: Request) {
        if groupBytes + request.bytes > JournalCodec.maximumPayload ||
            groupOperations + request.operations.count > JournalCodec.maximumOperations { drain() }
        requests.append(request)
        groupBytes += request.bytes
        groupOperations += request.operations.count
        if requests.count >= maximumGroupRequests { drain(); return }
        if timer == nil {
            let work = DispatchWorkItem { self.drain() }
            timer = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
    private func drain() {
        timer?.cancel(); timer = nil
        guard !requests.isEmpty else { return }
        let group = requests
        requests = []; groupBytes = 0; groupOperations = 0
        let result = Result { try store.writeBatch(group.flatMap(\.operations)) }
        admission.lock()
        pendingRequests -= group.count
        pendingBytes -= group.reduce(0) { $0 + $1.bytes }
        admission.unlock()
        for request in group { request.completion(result) }
    }
    public func flush() async throws { try await barrier(close: false) }
    /// Drains accepted requests and syncs the underlying store; it does not close that store.
    public func close() async throws { try await barrier(close: true) }
    private func barrier(close: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            admission.lock()
            if close { closed = true }
            queue.async {
                self.drain()
                do { try self.store.flush(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
            admission.unlock()
        }
    }
}
