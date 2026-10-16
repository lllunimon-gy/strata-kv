import Foundation

public enum CompactionProgress { case captured(keys: Int), built(keys: Int), published }
public struct CompactionReport: Codable {
    public let capturedKeys: Int
    public let checkpointBytes: Int64
    public let retiredSegments: Int
    public let cleanupFailures: [String]
}
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
extension KVStore {
    public func compact(progress: (CompactionProgress) -> Void = { _ in }) throws {
        _ = try performCompaction(checkCancellation: {}, progress: progress)
    }
    /// Cancellation before publication keeps the old manifest plus delta log usable.
    /// A cancellation racing publication may still return a successfully published result.
    public func compactInBackground(progress: @escaping (CompactionProgress) -> Void = { _ in }) async throws -> CompactionReport {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try self.performCompaction(checkCancellation: cancellation.check, progress: progress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
    func performCompaction(checkCancellation: () throws -> Void,
                           progress: (CompactionProgress) -> Void) throws -> CompactionReport {
        try checkCancellation()
        writerLock.lock()
        let captured: (FileRef, [String: Location], UInt64, [FileRef], DirectoryLease, Int, Int64)
        do {
            guard !compacting else { throw StoreError.compactionInProgress }
            captured = try locked {
                let source = try openFile()
                let time = try timeLocked()
                return (source, state.index.filter { visible($0.value, at: time) }, state.sequence, files, lease!, state.frameCount, logBytes)
            }
            do { try rotateLocked() } catch { locked { poisoned = true }; throw error }
            compacting = true
            writerLock.unlock()
        } catch { writerLock.unlock(); throw error }
        // Retain the directory lease until the worker finishes, even if close() races this work.
        defer {
            withExtendedLifetime(captured.4) {}
            writerLock.lock(); compacting = false; writerLock.unlock()
        }
        progress(.captured(keys: captured.1.count))
        let name = "segment-\(UUID().uuidString).log"
        let url = directory.appendingPathComponent(name)
        var publishing = false
        do {
            try checkCancellation()
            let output = try FileRef(url, writable: true)
            let checkpoint = try Rewriter.write(source: captured.0, index: captured.1, sequence: captured.2,
                                               to: output, checkpoint: true, checkCancellation: checkCancellation)
            if durability == .fullSync { try output.sync(.fullSync) }
            try syncDirectory(directory)
            progress(.built(keys: checkpoint.index.count))
            try checkCancellation()
            writerLock.lock()
            do {
                _ = try locked { try openFile() }
                try fault?(.compactionReady)
                try checkCancellation()
                let retired = Set(captured.3.map { $0.name })
                let deltas = files.filter { !retired.contains($0.name) }
                guard !deltas.isEmpty, manifest.generation < UInt64.max else { throw StoreError.invalidManifest }
                let replacement = Manifest(generation: manifest.generation + 1,
                                           files: [name] + deltas.map { $0.name })
                publishing = true
                try replacement.publish(directory, durability: durability)
                try fault?(.compactionReplaced)
                let checkpointBytes = try output.size
                locked {
                    // Replace only locations still pointing into the captured files. Concurrent
                    // updates and tombstones in delta logs win, including expired/reinserted keys.
                    for (key, location) in state.index {
                        if let source = location.source, retired.contains(source.name) {
                            state.index[key] = checkpoint.index[key]
                        }
                    }
                    files = [output] + deltas
                    manifest = replacement
                    state.frameCount = checkpoint.frameCount + state.frameCount - captured.5
                    logBytes = checkpointBytes + logBytes - captured.6
                    syncCount += 1
                }
                var failures: [String] = []
                for file in captured.3 {
                    do { try FileManager.default.removeItem(at: file.url) }
                    catch { failures.append(file.name) }
                }
                // Cleanup is best effort: the durable manifest already determines authority.
                try? syncDirectory(directory)
                writerLock.unlock()
                progress(.published)
                return CompactionReport(capturedKeys: captured.1.count, checkpointBytes: try output.size,
                                        retiredSegments: captured.3.count, cleanupFailures: failures)
            } catch { writerLock.unlock(); throw error }
        } catch {
            if publishing { locked { poisoned = true } }
            else { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    /// Removes only unreferenced Strata segment/temp names while holding the writer boundary.
    /// A successful open never silently deletes forensic evidence left by an interrupted operation.
    @discardableResult
    public func vacuumOrphans() throws -> [String] {
        writerLock.lock(); defer { writerLock.unlock() }
        _ = try locked { try openFile() }
        guard !compacting else { throw StoreError.compactionInProgress }
        let retained = Set(manifest.files)
        var removed: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let name = url.lastPathComponent
            let temporary = name.hasPrefix("manifest-") && name.hasSuffix(".tmp") &&
                UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil
            guard (Manifest.validName(name) || temporary), !retained.contains(name) else { continue }
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(name)
        }
        try syncDirectory(directory)
        return removed.sorted()
    }
}
