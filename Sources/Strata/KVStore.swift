import Foundation
import StrataObjC

public enum StoreError: Error {
    case directoryInUse, unsafeDirectory, invalidHeader, corruption(offset: Int)
    case invalidKey, invalidBatch, valueTooLarge, io(Int32), closed, requiresReopen
}
public enum Durability { case buffered, synchronized }
public enum WriteStage: String { case afterHeader, afterPayload, afterCommit, afterSync, compactionReady, compactionReplaced }
public struct Mutation {
    public let key: String
    public let value: Data?
    public static func put(_ key: String, _ value: Data) -> Mutation { Mutation(key: key, value: value) }
    public static func delete(_ key: String) -> Mutation { Mutation(key: key, value: nil) }
}
public struct StoreStatistics {
    public let keys: Int
    public let logBytes: Int
    public let sequence: UInt64
    public let recoveredTailBytes: Int
}

/// Synchronous, serialized storage. Invoke on a background executor; never from a UI hot path.
public final class KVStore {
    private let mutex = NSLock()
    private let directory: URL
    private let file: URL
    private var lockFD: Int32 = -1
    private var fd: Int32 = -1
    private var state: Recovery
    private var poisoned = false
    private let durability: Durability
    private let fault: ((WriteStage) throws -> Void)?
    private let recovered: Int

    public init(directory: URL, durability: Durability = .synchronized,
                fault: ((WriteStage) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StoreError.unsafeDirectory }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lockFD = root.appendingPathComponent(".strata.lock").path.withCString { STLock($0) }
        guard lockFD >= 0 else { throw StoreError.directoryInUse }
        let file = root.appendingPathComponent("store.log")
        let fd = file.path.withCString { STOpen($0) }
        guard fd >= 0 else { STClose(lockFD); throw StoreError.unsafeDirectory }
        var state: Recovery
        var recovered = 0
        do {
            let data = try Data(contentsOf: file)
            if data.isEmpty {
                try Self.write(JournalCodec.magic, fd: fd); try Self.check(STSync(fd))
                state = Recovery()
            } else {
                state = try JournalCodec.replay(data)
                recovered = data.count - state.validEnd
                if recovered > 0 { try Self.check(STTruncate(fd, Int64(state.validEnd))); try Self.check(STSync(fd)) }
            }
            let temporary = root.appendingPathComponent("store.compacting")
            if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        } catch { STClose(fd); STClose(lockFD); throw error }
        self.directory = root; self.file = file; self.durability = durability; self.fault = fault
        self.lockFD = lockFD; self.fd = fd; self.state = state; self.recovered = recovered
    }
    private static func check(_ code: Int32) throws { if code != 0 { throw StoreError.io(code) } }
    private static func write(_ data: Data, fd: Int32) throws {
        try check(data.withUnsafeBytes { STWrite(fd, $0.baseAddress, $0.count) })
    }
    private func ensureOpen() throws {
        guard fd >= 0 else { throw StoreError.closed }
        guard !poisoned else { throw StoreError.requiresReopen }
    }
    private func value(at location: Location) throws -> Data {
        var result = Data(count: location.length)
        try Self.check(result.withUnsafeMutableBytes { STRead(fd, $0.baseAddress, $0.count, location.offset) })
        return result
    }
    public func get(_ key: String) throws -> Data? {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen()
        guard let location = state.index[key] else { return nil }
        return try value(at: location)
    }
    public func keys() throws -> [String] {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen(); return state.index.keys.sorted()
    }
    public func put(_ key: String, value: Data) throws { try writeBatch([.put(key, value)]) }
    public func delete(_ key: String) throws { try writeBatch([.delete(key)]) }
    public func writeBatch(_ operations: [Mutation]) throws {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen()
        let sequence = state.sequence + 1
        let frame = try JournalCodec.encode(operations, sequence: sequence)
        do {
            try Self.write(frame.header, fd: fd); try fault?(.afterHeader)
            try Self.write(frame.payload, fd: fd); try fault?(.afterPayload)
            try Self.write(frame.trailer, fd: fd); try fault?(.afterCommit)
            if durability == .synchronized {
                try Self.check(STSync(fd))
                try fault?(.afterSync)
            }
            for change in frame.changes {
                state.index[change.key] = change.relativeOffset.map { Location(offset: Int64(state.validEnd + 24 + $0), length: change.length) }
            }
            state.frames.append(FrameSummary(sequence: sequence, offset: state.validEnd, payloadBytes: frame.payload.count, operations: operations.count))
            state.validEnd += frame.count; state.sequence = sequence
        } catch {
            // An append error can leave a partial or already committed tail. Never append after it.
            poisoned = true; throw error
        }
    }
    public func flush() throws {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen()
        do { try Self.check(STSync(fd)) } catch { poisoned = true; throw error }
    }
    public func statistics() throws -> StoreStatistics {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen()
        return StoreStatistics(keys: state.index.count, logBytes: state.validEnd, sequence: state.sequence, recoveredTailBytes: recovered)
    }
    public func frames() throws -> [FrameSummary] {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen(); return state.frames
    }
    public func compact() throws {
        mutex.lock(); defer { mutex.unlock() }; try ensureOpen()
        let temporary = directory.appendingPathComponent("store.compacting")
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        let output = temporary.path.withCString { STOpen($0) }
        guard output >= 0 else { throw StoreError.unsafeDirectory }
        defer { STClose(output) }
        do {
            try Self.write(JournalCodec.magic, fd: output)
            var sequence: UInt64 = 0
            var batch: [Mutation] = []
            var size = 0
            func emit() throws {
                guard !batch.isEmpty else { return }
                sequence += 1
                let frame = try JournalCodec.encode(batch, sequence: sequence)
                try Self.write(frame.header + frame.payload + frame.trailer, fd: output)
                batch.removeAll(keepingCapacity: true); size = 0
            }
            for key in state.index.keys.sorted() {
                let data = try value(at: state.index[key]!)
                let length = 9 + key.utf8.count + data.count
                if size + length > JournalCodec.maximumPayload || batch.count == JournalCodec.maximumOperations { try emit() }
                batch.append(.put(key, data)); size += length
            }
            try emit(); try Self.check(STSync(output)); try fault?(.compactionReady)
            let code = temporary.path.withCString { source in file.path.withCString { STRename(source, $0) } }
            try Self.check(code); try fault?(.compactionReplaced)
            STClose(fd); fd = file.path.withCString { STOpen($0) }
            guard fd >= 0 else { throw StoreError.requiresReopen }
            state = try JournalCodec.replay(Data(contentsOf: file))
        } catch { poisoned = true; throw error }
    }
    public func close() {
        mutex.lock(); defer { mutex.unlock() }
        STClose(fd); fd = -1; STClose(lockFD); lockFD = -1
    }
    deinit { STClose(fd); STClose(lockFD) }
}
