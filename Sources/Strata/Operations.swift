import Foundation

public struct StoredValue {
    public let value: Data
    public let revision: UInt64
    public let expiresAt: Date?
}
public enum CompareExchangeResult: Equatable {
    case applied(revision: UInt64)
    case conflict(currentRevision: UInt64?)
}
extension KVStore {
    /// expectedRevision=nil means "currently absent/expired", not "has never existed".
    public func compareExchange(_ key: String, expectedRevision: UInt64?, value: Data?,
                                expiresAt: Date? = nil) throws -> CompareExchangeResult {
        writerLock.lock(); defer { writerLock.unlock() }
        let current: UInt64? = try locked {
            _ = try openFile()
            let time = try timeLocked()
            return state.index[key].flatMap { visible($0, at: time) ? $0.revision : nil }
        }
        guard current == expectedRevision else { return .conflict(currentRevision: current) }
        let operation: Mutation = value.map { .put(key, $0, expiresAt: expiresAt) } ?? .delete(key)
        try appendLocked([operation])
        return .applied(revision: locked { state.sequence })
    }
    /// Expiration is logical first; this writes tombstones. Compaction reclaims physical bytes.
    @discardableResult
    public func purgeExpired(limit: Int = 256) throws -> Int {
        guard limit > 0, limit <= JournalCodec.maximumOperations else { throw StoreError.invalidBatch }
        writerLock.lock(); defer { writerLock.unlock() }
        let keys = try locked { () throws -> [String] in
            _ = try openFile()
            let time = try timeLocked()
            return Array(state.index.filter { !visible($0.value, at: time) }.keys.sorted().prefix(limit))
        }
        if !keys.isEmpty { try appendLocked(keys.map { .delete($0) }) }
        return keys.count
    }
    public func namespace(_ name: String) throws -> Namespace { try Namespace(store: self, name: name) }
    public func snapshot() throws -> StoreSnapshot {
        let (source, live, time) = try locked { () throws -> (FileRef, [String: Location], TimeInterval) in
            let source = try openFile()
            let time = try timeLocked()
            return (source, state.index.filter { visible($0.value, at: time) }, time)
        }
        return StoreSnapshot(source: source, entries: live, capturedAt: Date(timeIntervalSince1970: time))
    }
}
public struct Namespace {
    let store: KVStore
    let prefix: String
    public let name: String
    init(store: KVStore, name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 256 else { throw StoreError.invalidNamespace }
        self.store = store
        self.name = name
        self.prefix = "\u{1e}N\(name.utf8.count):\(name):"
    }
    public func key(_ local: String) throws -> String {
        guard !local.isEmpty, (prefix + local).utf8.count <= 1024 else { throw StoreError.invalidKey }
        return prefix + local
    }
    public func get(_ key: String) throws -> Data? { try store.get(self.key(key)) }
    public func entry(_ key: String) throws -> StoredValue? { try store.entry(self.key(key)) }
    public func put(_ key: String, value: Data, ttl: TimeInterval? = nil) throws { try store.put(self.key(key), value: value, ttl: ttl) }
    public func delete(_ key: String) throws { try store.delete(self.key(key)) }
    public func putMutation(_ key: String, value: Data, expiresAt: Date? = nil) throws -> Mutation {
        .put(try self.key(key), value, expiresAt: expiresAt)
    }
    public func deleteMutation(_ key: String) throws -> Mutation { .delete(try self.key(key)) }
    public func writeBatch(_ operations: [Mutation]) throws {
        let qualified = try operations.map { operation -> Mutation in
            Mutation(key: try key(operation.key), value: operation.value, revision: nil, expiration: operation.expiration)
        }
        try store.writeBatch(qualified)
    }
    public func compareExchange(_ key: String, expectedRevision: UInt64?, value: Data?, expiresAt: Date? = nil) throws -> CompareExchangeResult {
        try store.compareExchange(self.key(key), expectedRevision: expectedRevision, value: value, expiresAt: expiresAt)
    }
    public func snapshot() throws -> StoreSnapshot { try store.snapshot().scoped(prefix: prefix) }
}
