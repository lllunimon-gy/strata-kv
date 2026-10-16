import XCTest
@testable import Strata

final class StoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func testBatchEmptyValueDeleteAndReopen() throws {
        let store = try KVStore(directory: root)
        try store.writeBatch([.put("a", Data([1])), .put("empty", Data()), .put("a", Data([2]))])
        try store.delete("missing")
        store.close()
        let reopened = try KVStore(directory: root)
        XCTAssertEqual(try reopened.get("a"), Data([2]))
        XCTAssertEqual(try reopened.get("empty"), Data())
        XCTAssertEqual(try reopened.keys(), ["a", "empty"])
    }
    func testEveryTruncationOfSecondBatchIsAtomic() throws {
        try ensureDirectory(root)
        let first = try JournalCodec.encode([.put("a", Data([1]))], sequence: 1)
        let second = try JournalCodec.encode([.put("a", Data([2])), .put("b", Data([3]))], sequence: 2)
        let baseline = JournalCodec.fileHeader() + first.header + first.payload + first.trailer
        let full = baseline + second.header + second.payload + second.trailer
        let path = root.appendingPathComponent("store.log")
        for count in baseline.count..<full.count {
            try Data(full.prefix(count)).write(to: path)
            let result = try JournalCodec.scan(FileRef(path))
            XCTAssertEqual(result.sequence, 1, "cut=\(count)")
            XCTAssertEqual(result.index.keys.sorted(), ["a"])
            XCTAssertEqual(result.validEnd, Int64(baseline.count))
        }
        try full.write(to: path)
        XCTAssertEqual(try JournalCodec.scan(FileRef(path)).sequence, 2)
    }
    func testCorruptLengthWithinLimitNeverTruncatesEvidence() throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([7])); store.close()
        let path = root.appendingPathComponent("store.log")
        var bytes = try Data(contentsOf: path)
        bytes.replaceSubrange(28..<32, with: JournalCodec.integer(4096, width: 4))
        try bytes.write(to: path)
        XCTAssertThrowsError(try KVStore(directory: root))
        XCTAssertThrowsError(try KVStore.repairIncompleteTail(directory: root))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testReadOnlyInspectAndVerifyDoNotChangeIncompleteFile() throws {
        enum Fault: Error { case stop }
        let store = try KVStore(directory: root, fault: { if $0 == .afterPayload { throw Fault.stop } })
        XCTAssertThrowsError(try store.put("a", value: Data([1]))); store.close()
        let path = root.appendingPathComponent("store.log")
        let before = try Data(contentsOf: path)
        let report = try KVStore.inspect(directory: root, includeFrames: true)
        XCTAssertGreaterThan(report.incompleteTailBytes, 0)
        XCTAssertThrowsError(try KVStore.verify(directory: root))
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertThrowsError(try KVStore(directory: root, recovery: .strict))
        XCTAssertEqual(try Data(contentsOf: path), before)
        let repair = try KVStore.repairIncompleteTail(directory: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(repair.backup!)), before)
        XCTAssertEqual(try KVStore.verify(directory: root).keys, 0)
    }
    func testReadOnlyInspectionDoesNotCreateMissingDirectory() {
        XCTAssertThrowsError(try KVStore.inspect(directory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testReopenTruncatesPartialTailBeforeNextWrite() throws {
        enum Fault: Error { case stop }
        var enabled = false
        let store = try KVStore(directory: root, fault: { if enabled, $0 == .afterPayload { throw Fault.stop } })
        try store.put("a", value: Data([1])); enabled = true
        XCTAssertThrowsError(try store.writeBatch([.put("a", Data([2])), .put("b", Data([3]))]))
        XCTAssertThrowsError(try store.get("a")); store.close()
        let reopened = try KVStore(directory: root)
        XCTAssertEqual(try reopened.get("a"), Data([1])); XCTAssertNil(try reopened.get("b"))
        XCTAssertGreaterThan(try reopened.statistics().recoveredTailBytes, 0)
        try reopened.put("c", value: Data([4]))
    }
    func testCommittedButUnacknowledgedBatchSurvivesReopen() throws {
        enum Fault: Error { case stop }
        let store = try KVStore(directory: root, fault: { if $0 == .afterCommit { throw Fault.stop } })
        XCTAssertThrowsError(try store.put("a", value: Data([9]))); store.close()
        XCTAssertEqual(try KVStore(directory: root).get("a"), Data([9]))
    }
    func testPayloadAndFileHeaderCorruptionFailWithoutMutation() throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([7,8,9])); store.close()
        let path = root.appendingPathComponent("store.log")
        let good = try Data(contentsOf: path)
        for offset in [8, good.count - 17, good.count - 1] {
            var damaged = good; damaged[offset] ^= 0xff
            try damaged.write(to: path)
            XCTAssertThrowsError(try KVStore(directory: root))
            XCTAssertEqual(try Data(contentsOf: path), damaged)
        }
    }
    func testCompactionPreservesValuesAndSequenceHighWatermark() throws {
        let store = try KVStore(directory: root, durability: .buffered)
        for n in 0..<100 { try store.put("a", value: Data([UInt8(n)])) }
        try store.put("deleted", value: Data([1])); try store.delete("deleted")
        let before = try store.statistics()
        try store.compact()
        XCTAssertLessThan(try store.statistics().logBytes, before.logBytes)
        XCTAssertGreaterThan(try store.statistics().sequence, before.sequence)
        XCTAssertEqual(try store.get("a"), Data([99])); XCTAssertNil(try store.get("deleted"))
    }
    func testCompactionInterruptionBeforeAndAfterRename() throws {
        enum Fault: Error { case stop }
        for stage in [WriteStage.compactionReady, .compactionReplaced] {
            let directory = root.appendingPathComponent(stage.rawValue)
            let store = try KVStore(directory: directory, fault: { if $0 == stage { throw Fault.stop } })
            try store.put("a", value: Data([1])); try store.put("a", value: Data([2]))
            XCTAssertThrowsError(try store.compact()); store.close()
            XCTAssertEqual(try KVStore(directory: directory).get("a"), Data([2]))
        }
    }
    func testInvalidInputDoesNotPoisonWriterAndLeaseIsExclusive() throws {
        let store = try KVStore(directory: root)
        XCTAssertThrowsError(try KVStore(directory: root))
        XCTAssertThrowsError(try store.writeBatch([]))
        XCTAssertThrowsError(try store.put("", value: Data()))
        try store.put("valid", value: Data([1]))
        XCTAssertEqual(try store.get("valid"), Data([1]))
    }
    func testModelBasedRandomOperations() throws {
        let store = try KVStore(directory: root, durability: .buffered)
        var seed: UInt64 = 42
        var model: [String: Data] = [:]
        for n in 0..<500 {
            seed = seed &* 6364136223846793005 &+ 1
            let key = "k\(seed % 31)"
            if seed % 5 == 0 { try store.delete(key); model[key] = nil }
            else { let data = Data("value-\(n)".utf8); try store.put(key, value: data); model[key] = data }
            if n % 100 == 0 { try store.compact() }
        }
        XCTAssertEqual(try store.keys(), model.keys.sorted())
        for (key, value) in model { XCTAssertEqual(try store.get(key), value) }
    }
    func testRecoveryBufferDependsOnFrameNotHistory() throws {
        let store = try KVStore(directory: root, durability: .buffered)
        for n in 0..<2000 { try store.put("one-key", value: Data("value-\(n)".utf8)) }
        store.close()
        let report = try KVStore.inspect(directory: root)
        XCTAssertEqual(report.keys, 1)
        XCTAssertEqual(report.frameCount, 2000)
        XCTAssertTrue(report.frames.isEmpty)
        XCTAssertLessThan(report.maximumReadBytes, 128)
    }
    func testConcurrentCallersProduceARecoverableLog() throws {
        let store = try KVStore(directory: root, durability: .buffered)
        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 100) { n in
            do { try store.put("key-\(n)", value: Data("value-\(n)".utf8)) }
            catch { lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(failures, 0)
        try store.flush(); store.close()
        let reopened = try KVStore(directory: root)
        XCTAssertEqual(try reopened.keys().count, 100)
        for n in 0..<100 { XCTAssertEqual(try reopened.get("key-\(n)"), Data("value-\(n)".utf8)) }
    }
    func testCRCReferenceVector() { XCTAssertEqual(JournalCodec.checksum(Data("123456789".utf8)), 0xcbf43926) }
}
