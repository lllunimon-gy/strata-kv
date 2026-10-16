import Foundation

/// Single-process, multiple-reader store. File I/O never runs under the index mutex.
public final class KVStore: @unchecked Sendable {
    let mutex = NSLock()
    let writerLock = NSRecursiveLock()
    let directory: URL
    var file: FileRef?
    var files: [FileRef]
    var manifest: Manifest
    var lease: DirectoryLease?
    var state: Recovery
    var poisoned = false
    var compacting = false
    let durability: Durability
    let fault: ((WriteStage) throws -> Void)?
    let recovered: Int64
    let segmentBytes: Int64
    var logBytes: Int64
    var syncCount = 0
    // Reopened data may come from a previous buffered writer. Do not assume it was synced.
    var needsSync = true
    let clock: () -> Date
    var lastTime: TimeInterval = -.infinity

    public init(directory: URL, durability: Durability = .synchronized,
                recovery: RecoveryPolicy = .recoverIncompleteTail,
                segmentBytes: Int64 = 4 * 1024 * 1024,
                now: @escaping () -> Date = Date.init,
                fault: ((WriteStage) throws -> Void)? = nil) throws {
        guard segmentBytes >= 128 else { throw StoreError.invalidConfiguration }
        let root = directory.standardizedFileURL
        try ensureDirectory(root)
        let lease = try DirectoryLease(root)
        let existing = try Manifest.read(root)
        if existing == nil {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard !names.contains(where: { $0 != "store.log" && Manifest.validName($0) }) else {
                throw StoreError.invalidManifest
            }
        }
        let initial = root.appendingPathComponent("store.log")
        var syncs = 0
        if existing == nil, !FileManager.default.fileExists(atPath: initial.path) {
            let created = try FileRef(initial, writable: true)
            try created.append(JournalCodec.fileHeader())
            try created.sync(durability == .fullSync ? .fullSync : .synchronized)
            try syncDirectory(root)
            syncs += 1
        }
        let loaded = try JournalSet.load(root, manifest: existing)
        guard loaded.state.format == 2 else { throw StoreError.legacyFormat }
        let file = try FileRef(loaded.files.last!.url, writable: true)
        if loaded.tail > 0 {
            guard recovery == .recoverIncompleteTail else { throw StoreError.incompleteTail(bytes: loaded.tail) }
            try file.truncate(to: loaded.state.validEnd)
            try file.sync(durability == .fullSync ? .fullSync : .synchronized)
            syncs += 1
        }
        let manifest = existing ?? Manifest(generation: 0, files: ["store.log"])
        if existing == nil { try manifest.publish(root, durability: durability) }
        self.directory = root
        self.file = file
        self.files = loaded.files.dropLast() + [file]
        self.manifest = manifest
        self.lease = lease
        self.state = loaded.state
        self.durability = durability
        self.fault = fault
        self.recovered = loaded.tail
        self.logBytes = loaded.bytes - loaded.tail
        self.segmentBytes = segmentBytes
        self.syncCount = syncs
        self.needsSync = syncs == 0
        self.clock = now
    }
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }; return try body()
    }
    func openFile() throws -> FileRef {
        guard let file else { throw StoreError.closed }
        guard !poisoned else { throw StoreError.requiresReopen }
        return file
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
        let captured: (Location, FileRef)? = try locked {
            let active = try openFile()
            let time = try timeLocked()
            guard let location = state.index[key], visible(location, at: time) else { return nil }
            return (location, location.source ?? active)
        }
        guard let (location, source) = captured else { return nil }
        return StoredValue(value: try source.read(at: location.offset, count: location.length), revision: location.revision,
                           expiresAt: location.expiration.map { Date(timeIntervalSince1970: $0) })
    }
    public func keys() throws -> [String] {
        let entries: [String: Location] = try locked {
            _ = try openFile()
            let time = try timeLocked()
            return state.index.filter { visible($0.value, at: time) }
        }
        return entries.keys.sorted()
    }
    public func put(_ key: String, value: Data, ttl: TimeInterval? = nil) throws {
        writerLock.lock(); defer { writerLock.unlock() }
        var expires: Date?
        if let ttl {
            guard ttl.isFinite, ttl > 0 else { throw StoreError.invalidExpiration }
            let deadline = try locked { try timeLocked() } + ttl
            guard deadline.isFinite else { throw StoreError.invalidExpiration }
            expires = Date(timeIntervalSince1970: deadline)
        }
        try appendLocked([.put(key, value, expiresAt: expires)])
    }
    public func delete(_ key: String) throws { try writeBatch([.delete(key)]) }
    public func writeBatch(_ operations: [Mutation]) throws {
        writerLock.lock(); defer { writerLock.unlock() }
        try appendLocked(operations)
    }
    // Caller owns writerLock. Readers keep seeing the previous committed index during I/O.
    func appendLocked(_ operations: [Mutation]) throws {
        var (file, offset, sequence) = try locked { () throws -> (FileRef, Int64, UInt64) in
            let active = try openFile()
            guard state.sequence < UInt64.max else { throw StoreError.invalidBatch }
            return (active, state.validEnd, state.sequence + 1)
        }
        let frame = try JournalCodec.encode(operations, sequence: sequence)
        do {
            if offset > 24 && offset + Int64(frame.count) > segmentBytes {
                try rotateLocked()
                (file, offset) = try locked { (try openFile(), state.validEnd) }
            }
            if let fault {
                // Preserve exact interruption boundaries for fault experiments.
                try file.append(frame.header)
                try fault(.afterHeader)
                try file.append(frame.payload)
                try fault(.afterPayload)
                try file.append(frame.trailer)
                try fault(.afterCommit)
            } else {
                try file.append(frame)
            }
            if durability != .buffered {
                try file.sync(durability)
                try fault?(.afterSync)
            }
            locked {
                needsSync = durability == .buffered
                if !needsSync { syncCount += 1 }
                for change in frame.changes {
                    state.index[change.key] = change.offset.map {
                        Location(offset: offset + 28 + Int64($0), length: change.length,
                                 revision: change.revision, expiration: change.expiration, source: file)
                    }
                }
                state.validEnd += Int64(frame.count)
                logBytes += Int64(frame.count)
                state.sequence = sequence
                state.frameCount += 1
            }
        } catch { locked { poisoned = true }; throw error }
    }
    func rotateLocked() throws {
        let (old, sequence) = try locked { (try openFile(), state.sequence) }
        let syncOld = needsSync // writerLock owns this decision and all append/flush paths
        if syncOld { try old.sync(durability == .fullSync ? .fullSync : .synchronized) }
        let name = "segment-\(UUID().uuidString).log"
        let next = try FileRef(directory.appendingPathComponent(name), writable: true)
        try next.append(JournalCodec.fileHeader(baseSequence: sequence))
        try next.sync(durability == .fullSync ? .fullSync : .synchronized)
        try syncDirectory(directory)
        try fault?(.rotationReady)
        guard manifest.generation < UInt64.max else { throw StoreError.invalidManifest }
        let replacement = Manifest(generation: manifest.generation + 1, files: manifest.files + [name])
        try replacement.publish(directory, durability: durability)
        try fault?(.rotationPublished)
        locked {
            manifest = replacement
            file = next
            files.append(next)
            state.validEnd = 24
            logBytes += 24
            syncCount += syncOld ? 2 : 1
            needsSync = false
        }
    }
    public func flush() throws {
        writerLock.lock(); defer { writerLock.unlock() }
        let source = try locked { try openFile() }
        do {
            try source.sync(durability == .fullSync ? .fullSync : .synchronized)
            locked { syncCount += 1; needsSync = false }
        } catch { locked { poisoned = true }; throw error }
    }
    public func statistics() throws -> StoreStatistics {
        try locked {
            _ = try openFile()
            return StoreStatistics(keys: state.index.count, logBytes: logBytes, sequence: state.sequence,
                                   recoveredTailBytes: recovered, frameCount: state.frameCount,
                                   liveValueBytes: state.index.values.reduce(0) { $0 + Int64($1.length) },
                                   syncCount: syncCount, recoveryBufferBytes: state.maximumRead, segments: files.count)
        }
    }
    public func frames() throws -> [FrameSummary] {
        writerLock.lock(); defer { writerLock.unlock() }
        _ = try locked { try openFile() }
        var frames: [FrameSummary] = []
        _ = try JournalSet.load(directory) { frames.append($0) }
        return frames
    }
    public func close() {
        writerLock.lock(); defer { writerLock.unlock() }
        locked {
            file = nil
            files = []
            state.index = [:]
            lease = nil
        }
    }
}
