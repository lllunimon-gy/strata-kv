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
    let clock: () -> Date
    var lastTime: TimeInterval = -.infinity

    public init(directory: URL, durability: Durability = .synchronized,
                recovery: RecoveryPolicy = .recoverIncompleteTail,
                now: @escaping () -> Date = Date.init,
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
        self.clock = now
    }
    func openFile() throws -> FileRef {
        guard let file else { throw StoreError.closed }
        guard !poisoned else { throw StoreError.requiresReopen }
        return file
    }
    func readValue(_ location: Location) throws -> Data {
        try openFile().read(at: location.offset, count: location.length)
    }
    func timeLocked() throws -> TimeInterval {
        let proposed = clock().timeIntervalSince1970
        guard proposed.isFinite else { throw StoreError.invalidExpiration }
        lastTime = max(lastTime, proposed)
        return lastTime
    }
    func visible(_ location: Location, at time: TimeInterval) -> Bool {
        location.expiration.map { $0 > time } ?? true
    }
    public func get(_ key: String) throws -> Data? { try entry(key)?.value }
    public func entry(_ key: String) throws -> StoredValue? {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try openFile()
        let time = try timeLocked()
        guard let location = state.index[key], visible(location, at: time) else { return nil }
        return StoredValue(value: try readValue(location), revision: location.revision,
                           expiresAt: location.expiration.map { Date(timeIntervalSince1970: $0) })
    }
    public func keys() throws -> [String] {
        mutex.lock()
        defer { mutex.unlock() }
        _ = try openFile()
        let time = try timeLocked()
        return state.index.filter { visible($0.value, at: time) }.keys.sorted()
    }
    public func put(_ key: String, value: Data, ttl: TimeInterval? = nil) throws {
        mutex.lock()
        defer { mutex.unlock() }
        var expires: Date?
        if let ttl {
            guard ttl.isFinite, ttl > 0 else { throw StoreError.invalidExpiration }
            let deadline = try timeLocked() + ttl
            guard deadline.isFinite else { throw StoreError.invalidExpiration }
            expires = Date(timeIntervalSince1970: deadline)
        }
        try appendLocked([.put(key, value, expiresAt: expires)])
    }
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
            let time = try timeLocked()
            let live = state.index.filter { visible($0.value, at: time) }
            let replacement = try Rewriter.write(source: source, index: live, sequence: state.sequence, to: output)
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
