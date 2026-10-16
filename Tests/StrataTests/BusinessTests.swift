import XCTest
@testable import Strata

private final class Clock { var seconds: TimeInterval = 1000; func now() -> Date { Date(timeIntervalSince1970: seconds) } }
final class BusinessTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    func testNamespacesDoNotCollideAndCrossNamespaceBatchIsAtomic() throws {
        let store = try KVStore(directory: root)
        let first = try store.namespace("a:b"), second = try store.namespace("a")
        try store.writeBatch([first.putMutation("c", value: Data([1])), second.putMutation("b:c", value: Data([2]))])
        XCTAssertEqual(try first.get("c"), Data([1])); XCTAssertEqual(try second.get("b:c"), Data([2]))
        XCTAssertEqual(try first.entry("c")?.revision, try second.entry("b:c")?.revision)
        XCTAssertEqual(try first.snapshot().page().entries.map(\.key), ["c"])
    }
    func testTTLUsesInjectedClockAndDoesNotResurrectOnInProcessRollback() throws {
        let clock = Clock()
        let store = try KVStore(directory: root, now: clock.now)
        try store.put("a", value: Data([1]), ttl: 10)
        clock.seconds = 1009
        XCTAssertNotNil(try store.get("a"))
        clock.seconds = 1010
        XCTAssertNil(try store.get("a"))
        clock.seconds = 1001
        XCTAssertNil(try store.get("a"))
        XCTAssertEqual(try store.purgeExpired(), 1)
        XCTAssertEqual(try store.statistics().keys, 0)
    }
    func testTTLPersistsAcrossReopenAndCompactionPreservesDeadline() throws {
        let clock = Clock()
        let store = try KVStore(directory: root, now: clock.now)
        try store.put("a", value: Data([1]), ttl: 10)
        try store.compact(); store.close()
        clock.seconds = 1011
        let reopened = try KVStore(directory: root, now: clock.now)
        XCTAssertNil(try reopened.get("a"))
        try reopened.compact()
        XCTAssertEqual(try reopened.statistics().keys, 0)
    }
    func testSnapshotIsStableAcrossWritesExpiryCompactionAndClose() throws {
        let clock = Clock()
        let store = try KVStore(directory: root, now: clock.now)
        try store.put("a", value: Data([1]), ttl: 5)
        let snapshot = try store.snapshot()
        clock.seconds += 10
        try store.put("a", value: Data([2]))
        try store.put("b", value: Data([3]))
        try store.compact(); store.close()
        XCTAssertEqual(try snapshot.get("a")?.value, Data([1]))
        XCTAssertNil(try snapshot.get("b"))
    }
    func testPaginationHasNoDuplicatesAndRejectsForeignOrChangedQueryCursor() throws {
        let store = try KVStore(directory: root)
        for key in ["a1", "a2", "a3", "b1"] { try store.put(key, value: Data(key.utf8)) }
        let snapshot = try store.snapshot()
        let page = try snapshot.page(prefix: "a", limit: 2)
        XCTAssertEqual(page.entries.map(\.key), ["a1", "a2"])
        let last = try snapshot.page(prefix: "a", after: page.next, limit: 2)
        XCTAssertEqual(last.entries.map(\.key), ["a3"]); XCTAssertNil(last.next)
        XCTAssertThrowsError(try snapshot.page(prefix: "b", after: page.next))
        XCTAssertThrowsError(try store.snapshot().page(prefix: "a", after: page.next))
    }
    func testCASRevisionSurvivesCompactionAndDetectsABA() throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([1]))
        let first = try store.entry("a")!.revision
        try store.compact()
        XCTAssertEqual(try store.entry("a")?.revision, first)
        try store.put("a", value: Data([2])); try store.put("a", value: Data([1]))
        let current = try store.entry("a")!.revision
        XCTAssertNotEqual(first, current)
        XCTAssertEqual(try store.compareExchange("a", expectedRevision: first, value: Data([3])), .conflict(currentRevision: current))
        guard case .applied = try store.compareExchange("a", expectedRevision: current, value: Data([3])) else { return XCTFail("CAS") }
        XCTAssertEqual(try store.get("a"), Data([3]))
    }
    func testConcurrentCASHasExactlyOneWinner() throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([0]))
        let revision = try store.entry("a")!.revision
        let lock = NSLock()
        var winners = 0, failures = 0
        DispatchQueue.concurrentPerform(iterations: 20) { n in
            do {
                if case .applied = try store.compareExchange("a", expectedRevision: revision, value: Data([UInt8(n)])) {
                    lock.lock(); winners += 1; lock.unlock()
                }
            } catch { lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(winners, 1); XCTAssertEqual(failures, 0)
    }
    func testExpiredValueCountsAsAbsentForCAS() throws {
        let clock = Clock(), store = try KVStore(directory: root, now: clock.now)
        try store.put("a", value: Data([1]), ttl: 1)
        clock.seconds += 2
        guard case .applied = try store.compareExchange("a", expectedRevision: nil, value: Data([2])) else { return XCTFail("insert") }
        XCTAssertEqual(try store.get("a"), Data([2]))
    }
    func testTypedMigrationPreservesExpirationAndFailedMigrationPreservesBytes() throws {
        struct Old: Codable { let page: Int }
        struct New: Codable { let page: Int; let theme: String }
        let clock = Clock(), store = try KVStore(directory: root, now: clock.now)
        let ns = try store.namespace("reader")
        try ns.set(Old(page: 42), for: CodableKey("state"), ttl: 10)
        let original = try ns.entry("state")!
        let invalid = CodableKey<New>("state", schemaVersion: 2, migrations: [1: { _ in Data([0xff]) }])
        XCTAssertThrowsError(try ns.read(invalid))
        XCTAssertEqual(try ns.entry("state")?.value, original.value)
        let key = CodableKey<New>("state", schemaVersion: 2, migrations: [1: { data in
            let value = try JSONDecoder().decode(Old.self, from: data)
            return try JSONEncoder().encode(New(page: value.page, theme: "light"))
        }])
        let value = try ns.read(key)
        XCTAssertEqual(value?.value.page, 42); XCTAssertEqual(value?.migrated, true)
        XCTAssertEqual(try ns.entry("state")?.expiresAt, original.expiresAt)
        XCTAssertThrowsError(try ns.read(CodableKey<Old>("state")))
    }
    func testMigrationCannotOverwriteConcurrentNewSchemaWrite() throws {
        struct Old: Codable { let page: Int }
        struct New: Codable { let page: Int; let theme: String }
        let store = try KVStore(directory: root)
        let ns = try store.namespace("reader")
        try ns.set(Old(page: 1), for: CodableKey("state"))
        let newKey = CodableKey<New>("state", schemaVersion: 2)
        let migrating = CodableKey<New>("state", schemaVersion: 2, migrations: [1: { _ in
            try ns.set(New(page: 99, theme: "dark"), for: newKey)
            return try JSONEncoder().encode(New(page: 1, theme: "light"))
        }])
        XCTAssertEqual(try ns.read(migrating)?.value.page, 99)
    }
    func testBackupRestoreIsConsistentAndRefusesExistingDestination() throws {
        let store = try KVStore(directory: root.appendingPathComponent("source"))
        try store.writeBatch([.put("a", Data([1])), .put("b", Data([2]))])
        let backup = root.appendingPathComponent("backup")
        _ = try store.backup(to: backup)
        try store.put("a", value: Data([9]))
        let target = root.appendingPathComponent("restored")
        _ = try KVStore.restoreBackup(from: backup, to: target)
        let restored = try KVStore(directory: target)
        XCTAssertEqual(try restored.get("a"), Data([1])); XCTAssertEqual(try restored.get("b"), Data([2]))
        XCTAssertThrowsError(try KVStore.restoreBackup(from: backup, to: target))
    }
    func testCorruptBackupDoesNotPublishRestore() throws {
        let backup = root.appendingPathComponent("bad")
        try ensureDirectory(backup)
        try Data([1,2,3]).write(to: backup.appendingPathComponent("store.log"))
        let target = root.appendingPathComponent("restored")
        XCTAssertThrowsError(try KVStore.restoreBackup(from: backup, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
