import Foundation

public struct CodableKey<Value: Codable> {
    public let name: String
    public let schemaVersion: Int
    public let migrations: [Int: (Data) throws -> Data]
    public init(_ name: String, schemaVersion: Int = 1, migrations: [Int: (Data) throws -> Data] = [:]) {
        precondition(schemaVersion > 0)
        self.name = name
        self.schemaVersion = schemaVersion
        self.migrations = migrations
    }
}
public struct TypedRead<Value> {
    public let value: Value
    public let revision: UInt64
    public let migrated: Bool
}
private struct ValueEnvelope: Codable { let schema: Int; let payload: Data }
extension Namespace {
    public func set<T>(_ value: T, for key: CodableKey<T>, ttl: TimeInterval? = nil) throws {
        let payload = try JSONEncoder().encode(value)
        let envelope = try JSONEncoder().encode(ValueEnvelope(schema: key.schemaVersion, payload: payload))
        try put(key.name, value: envelope, ttl: ttl)
    }
    /// Migrations run outside the store lock. CAS prevents overwriting a concurrent business write.
    public func read<T>(_ key: CodableKey<T>) throws -> TypedRead<T>? {
        for _ in 0..<3 {
            guard let stored = try entry(key.name) else { return nil }
            guard let envelope = try? JSONDecoder().decode(ValueEnvelope.self, from: stored.value), envelope.schema > 0 else {
                throw StoreError.invalidEnvelope
            }
            guard envelope.schema <= key.schemaVersion else { throw StoreError.futureSchema }
            var schema = envelope.schema
            var payload = envelope.payload
            while schema < key.schemaVersion {
                guard let migration = key.migrations[schema] else { throw StoreError.missingMigration(schema) }
                payload = try migration(payload)
                schema += 1
            }
            guard let decoded = try? JSONDecoder().decode(T.self, from: payload) else { throw StoreError.decodingFailed }
            if schema == envelope.schema { return TypedRead(value: decoded, revision: stored.revision, migrated: false) }
            let upgraded = try JSONEncoder().encode(ValueEnvelope(schema: schema, payload: payload))
            let result = try compareExchange(key.name, expectedRevision: stored.revision, value: upgraded, expiresAt: stored.expiresAt)
            if case .applied(let revision) = result { return TypedRead(value: decoded, revision: revision, migrated: true) }
        }
        throw StoreError.migrationConflict
    }
}
