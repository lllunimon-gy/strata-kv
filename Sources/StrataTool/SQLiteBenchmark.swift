import Foundation
import CSQLite

struct SQLiteSample: Codable {
    let name: String
    let sqliteVersion: String
    let configuration: String
    let calls: Int
    let batchSize: Int
    let valueBytes: Int
    let p50Microseconds: Double
    let p95Microseconds: Double
    let p99Microseconds: Double
    let totalSeconds: Double
    let databaseAndWALBytes: Int64
}
private struct SQLiteFailure: Error { let code: Int32; let operation: String }
func sqliteBenchmark(directory: URL, calls: Int, batchSize: Int) throws -> SQLiteSample {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    let opened = sqlite3_open(directory.appendingPathComponent("reference.sqlite").path, &db)
    guard opened == SQLITE_OK else { sqlite3_close(db); throw SQLiteFailure(code: opened, operation: "open") }
    defer { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw SQLiteFailure(code: code, operation: sql) }
    }
    try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=OFF; PRAGMA checkpoint_fullfsync=OFF; PRAGMA wal_autocheckpoint=0;")
    try execute("CREATE TABLE kv (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID;")
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv(key,value) VALUES(?,?);", -1, &statement, nil)
    guard prepared == SQLITE_OK else { throw SQLiteFailure(code: prepared, operation: "prepare") }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let value = Data(repeating: 97, count: 256)
    var times: [Double] = []
    for n in 0..<calls {
        let start = ProcessInfo.processInfo.systemUptime
        try execute("BEGIN IMMEDIATE;")
        for offset in 0..<batchSize {
            let key = "k\(n * batchSize + offset)"
            let boundKey = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            let boundValue = value.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
            guard boundKey == SQLITE_OK, boundValue == SQLITE_OK else { throw SQLiteFailure(code: SQLITE_ERROR, operation: "bind") }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw SQLiteFailure(code: result, operation: "step") }
            let reset = sqlite3_reset(statement)
            guard reset == SQLITE_OK else { throw SQLiteFailure(code: reset, operation: "reset") }
        }
        try execute("COMMIT;")
        times.append(ProcessInfo.processInfo.systemUptime - start)
    }
    let total = times.reduce(0,+)
    times.sort()
    func percentile(_ q: Double) -> Double { times[min(times.count - 1, Int(Double(times.count - 1) * q))] * 1_000_000 }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.reduce(Int64(0)) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    return SQLiteSample(name: "sqlite-sync-write-batch-\(batchSize)", sqliteVersion: String(cString: sqlite3_libversion()),
                        configuration: "WAL; synchronous=FULL; fullfsync=OFF; wal_autocheckpoint=0; WITHOUT ROWID; prepared statement. Bytes include db/WAL/SHM before close/checkpoint.",
                        calls: calls, batchSize: batchSize, valueBytes: 256, p50Microseconds: percentile(0.5),
                        p95Microseconds: percentile(0.95), p99Microseconds: percentile(0.99), totalSeconds: total,
                        databaseAndWALBytes: bytes)
}
