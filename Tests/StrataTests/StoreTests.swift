import XCTest
@testable import Strata

final class StoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    func testBatchDeleteEmptyValueAndReopen() throws {
        let store = try KVStore(directory: root)
        try store.writeBatch([.put("a", Data([1])), .put("empty", Data()), .put("a", Data([2]))])
        try store.delete("missing")
        XCTAssertEqual(try store.get("a"), Data([2])); XCTAssertEqual(try store.get("empty"), Data())
        store.close()
        let reopened = try KVStore(directory: root); defer { reopened.close() }
        XCTAssertEqual(try reopened.keys(), ["a", "empty"])
        XCTAssertEqual(try reopened.get("a"), Data([2]))
    }
    func testEveryTruncationOfSecondBatchIsAtomic() throws {
        let first = try JournalCodec.encode([.put("a", Data([1]))], sequence: 1)
        let second = try JournalCodec.encode([.put("a", Data([2])), .put("b", Data([3]))], sequence: 2)
        let baseline = JournalCodec.magic + first.header + first.payload + first.trailer
        let full = baseline + second.header + second.payload + second.trailer
        for count in baseline.count..<full.count {
            let recovery = try JournalCodec.replay(Data(full.prefix(count)))
            XCTAssertEqual(recovery.sequence, 1, "cut=\(count)")
            XCTAssertEqual(recovery.index.keys.sorted(), ["a"])
            XCTAssertEqual(recovery.validEnd, baseline.count)
        }
        XCTAssertEqual(try JournalCodec.replay(full).sequence, 2)
    }
    func testReopenTruncatesPartialTailBeforeNextWrite() throws {
        enum Fault: Error { case stop }
        var enabled = false
        let store = try KVStore(directory: root, fault: { if enabled, $0 == .afterPayload { throw Fault.stop } })
        try store.put("a", value: Data([1])); enabled = true
        XCTAssertThrowsError(try store.writeBatch([.put("a", Data([2])), .put("b", Data([3]))]))
        XCTAssertThrowsError(try store.get("a")); store.close()
        let reopened = try KVStore(directory: root); defer { reopened.close() }
        XCTAssertEqual(try reopened.get("a"), Data([1])); XCTAssertNil(try reopened.get("b"))
        XCTAssertGreaterThan(try reopened.statistics().recoveredTailBytes, 0)
        try reopened.put("c", value: Data([4]))
        XCTAssertEqual(try reopened.get("c"), Data([4]))
    }
    func testCommittedButUnacknowledgedBatchSurvivesProcessStyleReopen() throws {
        enum Fault: Error { case stop }
        let store = try KVStore(directory: root, fault: { if $0 == .afterCommit { throw Fault.stop } })
        XCTAssertThrowsError(try store.put("a", value: Data([9]))); store.close()
        let reopened = try KVStore(directory: root); defer { reopened.close() }
        XCTAssertEqual(try reopened.get("a"), Data([9]))
    }
    func testChecksumCorruptionFailsWithoutModifyingEvidence() throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([7,8,9])); store.close()
        let file = root.appendingPathComponent("store.log")
        var bytes = try Data(contentsOf: file); bytes[bytes.count-5] ^= 0xff
        try bytes.write(to: file)
        XCTAssertThrowsError(try KVStore(directory: root))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testCompactionPreservesValuesAndShrinksLog() throws {
        let store = try KVStore(directory: root); defer { store.close() }
        for n in 0..<100 { try store.put("a", value: Data([UInt8(n)])) }
        try store.put("deleted", value: Data([1])); try store.delete("deleted")
        let before = try store.statistics().logBytes
        try store.compact()
        XCTAssertLessThan(try store.statistics().logBytes, before)
        XCTAssertEqual(try store.get("a"), Data([99])); XCTAssertNil(try store.get("deleted"))
        try store.put("b", value: Data([2]))
    }
    func testCompactionInterruptionBeforeAndAfterRename() throws {
        enum Fault: Error { case stop }
        for stage in [WriteStage.compactionReady, .compactionReplaced] {
            let directory = root.appendingPathComponent(stage.rawValue)
            let store = try KVStore(directory: directory, fault: { if $0 == stage { throw Fault.stop } })
            try store.put("a", value: Data([1])); try store.put("a", value: Data([2]))
            XCTAssertThrowsError(try store.compact()); store.close()
            let reopened = try KVStore(directory: directory)
            XCTAssertEqual(try reopened.get("a"), Data([2])); reopened.close()
        }
    }
    func testInvalidInputDoesNotPoisonWriterAndLeaseIsExclusive() throws {
        let store = try KVStore(directory: root); defer { store.close() }
        XCTAssertThrowsError(try KVStore(directory: root))
        XCTAssertThrowsError(try store.writeBatch([]))
        XCTAssertThrowsError(try store.put("", value: Data()))
        try store.put("valid", value: Data([1]))
        XCTAssertEqual(try store.get("valid"), Data([1]))
    }
    func testModelBasedRandomOperations() throws {
        let store = try KVStore(directory: root, durability: .buffered); defer { store.close() }
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
    func testCRCReferenceVectorAndLengthLimits() throws {
        XCTAssertEqual(JournalCodec.checksum(Data("123456789".utf8)), 0xcbf43926)
        let frame = try JournalCodec.encode([.put("a", Data([1]))], sequence: 1)
        var bytes = JournalCodec.magic + frame.header + frame.payload + frame.trailer
        bytes.replaceSubrange(12..<16, with: [0xff,0xff,0xff,0xff])
        XCTAssertThrowsError(try JournalCodec.replay(bytes))
    }
}
