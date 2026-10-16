import Foundation

/// A single-process store. Synchronous methods should run away from the main thread.
public final class KVStore {
    let mutex = NSLock()
    let directory: URL
    var file: FileRef?
    var lease: DirectoryLease?
    var state: Recovery
    var poisoned = false
    let durability: Durability
    let fault: ((WriteStage) throws -> Void)?
    let recovered: Int64
    var syncCount = 0

    public init(directory: URL, durability: Durability = .synchronized,
                recovery: RecoveryPolicy = .recoverIncompleteTail,
                fault: ((WriteStage) throws -> Void)? = nil) throws {
        let root = directory.standardizedFileURL
        try ensureDirectory(root)
        let lease = try DirectoryLease(root)
        let file = try FileRef(root.appendingPathComponent("store.log"), writable: true)
        var syncCount = 0
        if try file.size == 0 {
            try file.append(JournalCodec.fileHeader())
            try file.sync()
            try syncDirectory(root)
            syncCount += 1
        }
        let state = try JournalCodec.scan(file)
        guard state.format == 2 else { throw StoreError.legacyFormat }
        let recovered = try file.size - state.validEnd
        if recovered > 0 {
            guard recovery == .recoverIncompleteTail else { throw StoreError.incompleteTail(bytes: recovered) }
            try file.truncate(to: state.validEnd)
            try file.sync()
            syncCount += 1
        }
        self.directory = root
        self.file = file
        self.lease = lease
        self.state = state
        self.durability = durability
        self.fault = fault
        self.recovered = recovered
        self.syncCount = syncCount
    }
    func openFile() throws -> FileRef {
        guard let file else { throw StoreError.closed }
        guard !poisoned else { throw StoreError.requiresReopen }
        return file
    }
    func readValue(_ location: Location) throws -> Data {
        try openFile().read(at: location.offset, count: location.length)
    }
    public func get(_ key: String) throws -> Data? {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try openFile()
        guard let location = state.index[key] else { return nil }
        return try readValue(location)
    }
    public func keys() throws -> [String] {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try openFile()
        return state.index.keys.sorted()
    }
    public func put(_ key: String, value: Data) throws { try writeBatch([.put(key, value)]) }
    public func delete(_ key: String) throws { try writeBatch([.delete(key)]) }
    public func writeBatch(_ operations: [Mutation]) throws {
        mutex.lock()
        defer { mutex.unlock() }
        try appendLocked(operations)
    }
    func appendLocked(_ operations: [Mutation]) throws {
        let file = try openFile()
        guard state.sequence < UInt64.max else { throw StoreError.invalidBatch }
        let sequence = state.sequence + 1
        let frame = try JournalCodec.encode(operations, sequence: sequence)
        do {
            try file.append(frame.header)
            try fault?(.afterHeader)
            try file.append(frame.payload)
            try fault?(.afterPayload)
            try file.append(frame.trailer)
            try fault?(.afterCommit)
            if durability != .buffered {
                try file.sync(durability)
                syncCount += 1
                try fault?(.afterSync)
            }
            for change in frame.changes {
                state.index[change.key] = change.offset.map {
                    Location(offset: state.validEnd + 28 + Int64($0), length: change.length,
                             revision: change.revision, expiration: change.expiration)
                }
            }
            state.validEnd += Int64(frame.count)
            state.sequence = sequence
            state.frameCount += 1
        } catch {
            poisoned = true
            throw error
        }
    }
    public func flush() throws {
        mutex.lock()
        defer { mutex.unlock() }
        let file = try openFile()
        do {
            try file.sync(durability == .fullSync ? .fullSync : .synchronized)
            syncCount += 1
        } catch { poisoned = true; throw error }
    }
    public func statistics() throws -> StoreStatistics {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try openFile()
        return StoreStatistics(keys: state.index.count, logBytes: state.validEnd, sequence: state.sequence,
                               recoveredTailBytes: recovered, frameCount: state.frameCount,
                               liveValueBytes: state.index.values.reduce(0) { $0 + Int64($1.length) },
                               syncCount: syncCount, recoveryBufferBytes: state.maximumRead)
    }
    public func frames() throws -> [FrameSummary] {
        mutex.lock()
        defer { mutex.unlock() }
        var frames: [FrameSummary] = []
        _ = try JournalCodec.scan(openFile()) { frames.append($0) }
        return frames
    }
    public func compact() throws {
        mutex.lock()
        defer { mutex.unlock() }
        let source = try openFile()
        let temporary = directory.appendingPathComponent("compact-\(UUID().uuidString).tmp")
        let output = try FileRef(temporary, writable: true)
        do {
            let replacement = try Rewriter.write(source: source, index: state.index, sequence: state.sequence, to: output)
            syncCount += 1
            try fault?(.compactionReady)
            try replaceFile(temporary, directory.appendingPathComponent("store.log"))
            try fault?(.compactionReplaced)
            file = try FileRef(directory.appendingPathComponent("store.log"), writable: true)
            state = replacement
        } catch { poisoned = true; throw error }
    }
    public func close() {
        mutex.lock()
        defer { mutex.unlock() }
        file = nil
        lease = nil
    }
}
