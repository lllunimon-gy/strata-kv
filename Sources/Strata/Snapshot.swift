import Foundation

public struct PageCursor: Codable {
    let snapshotID: UUID
    let prefix: String
    let lastKey: String
}
public struct SnapshotEntry {
    public let key: String
    public let value: Data
    public let revision: UInt64
    public let expiresAt: Date?
}
public struct SnapshotPage {
    public let entries: [SnapshotEntry]
    public let next: PageCursor?
}
/// Immutable entries and retained file descriptor. Safe for concurrent pread and valid after store.close().
public final class StoreSnapshot: @unchecked Sendable {
    private let id = UUID()
    let source: FileRef
    let entries: [String: Location]
    private let ordered: [String]
    public let capturedAt: Date
    init(source: FileRef, entries: [String: Location], capturedAt: Date) {
        self.source = source
        self.entries = entries
        self.ordered = entries.keys.sorted()
        self.capturedAt = capturedAt
    }
    public func get(_ key: String) throws -> StoredValue? {
        guard let location = entries[key] else { return nil }
        return StoredValue(value: try (location.source ?? source).read(at: location.offset, count: location.length), revision: location.revision,
                           expiresAt: location.expiration.map { Date(timeIntervalSince1970: $0) })
    }
    func scoped(prefix: String) -> StoreSnapshot {
        let scoped = Dictionary(uniqueKeysWithValues: entries.filter { $0.key.hasPrefix(prefix) }.map {
            (String($0.key.dropFirst(prefix.count)), $0.value)
        })
        return StoreSnapshot(source: source, entries: scoped, capturedAt: capturedAt)
    }
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ordered[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }
    public func page(prefix: String = "", after cursor: PageCursor? = nil, limit: Int = 100) throws -> SnapshotPage {
        guard limit > 0, limit <= 1000 else { throw StoreError.invalidBatch }
        var position = lowerBound(prefix)
        if let cursor {
            guard cursor.snapshotID == id, cursor.prefix == prefix, entries[cursor.lastKey] != nil,
                  cursor.lastKey.hasPrefix(prefix) else { throw StoreError.invalidCursor }
            position = lowerBound(cursor.lastKey) + 1
        }
        var values: [SnapshotEntry] = []
        while position < ordered.count, ordered[position].hasPrefix(prefix), values.count < limit {
            let key = ordered[position]
            if let value = try get(key) {
                values.append(SnapshotEntry(key: key, value: value.value, revision: value.revision, expiresAt: value.expiresAt))
            }
            position += 1
        }
        let hasMore = position < ordered.count && ordered[position].hasPrefix(prefix)
        let next = hasMore ? values.last.map { PageCursor(snapshotID: id, prefix: prefix, lastKey: $0.key) } : nil
        return SnapshotPage(entries: values, next: next)
    }
}
