import XCTest
import Darwin
import StrataObjC
@testable import Strata

private final class VectorSink {
    var bytes = Data()
    var calls = 0
    var stopWithZero = false
    var failAfter: Int?
}
private let shortWriter: STVectorWriter = { _, vectors, count, context in
    let sink = Unmanaged<VectorSink>.fromOpaque(context!).takeUnretainedValue()
    sink.calls += 1
    if sink.calls == 1 { errno = EINTR; return -1 }
    if sink.stopWithZero { return 0 }
    if let limit = sink.failAfter, sink.calls >= limit { errno = ENOSPC; return -1 }
    var budget = sink.calls % 2 == 0 ? 1 : 31
    var written = 0
    for i in 0..<Int(count) {
        let vector = vectors![i]
        let length = min(budget, vector.iov_len)
        if length > 0 { sink.bytes.append(vector.iov_base!.assumingMemoryBound(to: UInt8.self), count: length) }
        budget -= length; written += length
        if budget == 0 { break }
    }
    return written
}
final class PerformanceSafetyTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func drive(_ parts: [Data], sink: VectorSink) -> Int32 {
        var a = parts[0], b = parts[1], c = parts[2]
        return a.withUnsafeMutableBytes { first in
            b.withUnsafeMutableBytes { second in
                c.withUnsafeMutableBytes { third in
                    var vectors = [iovec(iov_base: first.baseAddress, iov_len: first.count),
                                   iovec(iov_base: second.baseAddress, iov_len: second.count),
                                   iovec(iov_base: third.baseAddress, iov_len: third.count)]
                    return vectors.withUnsafeMutableBufferPointer {
                        STWriteVectorsUsing(-1, $0.baseAddress, Int32($0.count), shortWriter, Unmanaged.passUnretained(sink).toOpaque())
                    }
                }
            }
        }
    }
    func testVectorWriteRetriesEINTRAndAdvancesAcrossPartialBuffers() {
        for lengths in [[28, 256, 16], [0, 31, 0], [28, 0, 16], [0, 0, 0]] {
            let parts = lengths.enumerated().map { Data(repeating: UInt8($0.offset + 1), count: $0.element) }
            let sink = VectorSink()
            XCTAssertEqual(drive(parts, sink: sink), 0)
            XCTAssertEqual(sink.bytes, parts.reduce(Data(), +))
        }
    }
    func testVectorWriteReportsZeroAndDiskFullWithoutSpinning() {
        let parts = [Data(repeating: 1, count: 28), Data(repeating: 2, count: 256), Data(repeating: 3, count: 16)]
        let zero = VectorSink(); zero.stopWithZero = true
        XCTAssertEqual(drive(parts, sink: zero), EIO)
        XCTAssertEqual(zero.calls, 2)
        let full = VectorSink(); full.failAfter = 4
        XCTAssertEqual(drive(parts, sink: full), ENOSPC)
        XCTAssertEqual(full.calls, 4)
        XCTAssertEqual(full.bytes, Data(parts.reduce(Data(), +).prefix(full.bytes.count)))
    }
    func testFastAndFaultPathsProduceIdenticalBytesAndRevisions() throws {
        let fastURL = root.appendingPathComponent("fast"), stagedURL = root.appendingPathComponent("staged")
        let fast = try KVStore(directory: fastURL, durability: .buffered)
        let staged = try KVStore(directory: stagedURL, durability: .buffered, fault: { _ in })
        let operations: [Mutation] = [.put("中文-key", Data([0, 255])), .put("empty", Data()),
                                     .put("expires", Data([7]), expiresAt: Date(timeIntervalSince1970: 4_000_000_000)),
                                     .delete("missing")]
        try fast.writeBatch(operations); try staged.writeBatch(operations)
        try fast.writeBatch([.delete("empty"), .put("中文-key", Data([1]))])
        try staged.writeBatch([.delete("empty"), .put("中文-key", Data([1]))])
        try fast.flush(); try staged.flush(); fast.close(); staged.close()
        XCTAssertEqual(try Data(contentsOf: fastURL.appendingPathComponent("store.log")),
                       try Data(contentsOf: stagedURL.appendingPathComponent("store.log")))
        let reopened = try KVStore(directory: fastURL)
        XCTAssertEqual(try reopened.entry("中文-key")?.revision, 2)
        XCTAssertEqual(try reopened.get("中文-key"), Data([1]))
        XCTAssertNil(try reopened.get("empty"))
    }
    func testValidationCountsUTF8AndRejectsBoundsBeforeAllocatingPayload() throws {
        let value = Data(repeating: 1, count: JournalCodec.maximumValue)
        XCTAssertEqual(try JournalCodec.validatedSize([.put("键", value)], sequence: 1), 25 + 3 + value.count)
        XCTAssertThrowsError(try JournalCodec.validatedSize([.put("a", value), .put("b", value)], sequence: 1))
        XCTAssertThrowsError(try JournalCodec.validatedSize([.put("a", Data(), expiresAt: Date(timeIntervalSince1970: .infinity))], sequence: 1))
        var revision = Mutation.put("a", Data()); revision.revision = 2
        XCTAssertThrowsError(try JournalCodec.encode([revision], sequence: 1))
    }
    func testRotationSkipsOnlyKnownSynchronizedData() throws {
        let synchronized = try KVStore(directory: root.appendingPathComponent("sync"), segmentBytes: 128)
        try synchronized.put("a", value: Data([1])); try synchronized.put("b", value: Data([2]))
        XCTAssertEqual(try synchronized.statistics().syncCount, 4) // initial, a, next header, b
        let bufferedURL = root.appendingPathComponent("buffered")
        let buffered = try KVStore(directory: bufferedURL, durability: .buffered, segmentBytes: 128)
        try buffered.put("a", value: Data([1])); try buffered.put("b", value: Data([2]))
        XCTAssertEqual(try buffered.statistics().syncCount, 3) // initial, dirty old segment, next header
        buffered.close()
        let reopened = try KVStore(directory: bufferedURL, segmentBytes: 128)
        try reopened.put("c", value: Data([3]))
        XCTAssertEqual(try reopened.statistics().syncCount, 3) // reopened old segment must be synced
        XCTAssertEqual(try reopened.keys(), ["a", "b", "c"])
    }
    func testValueOnlyReadKeepsEntryExpirationAndClockRollbackSemantics() throws {
        var now = Date(timeIntervalSince1970: 100)
        let store = try KVStore(directory: root, now: { now })
        try store.put("ttl", value: Data([1]), ttl: 10)
        try store.put("plain", value: Data([2]))
        XCTAssertEqual(try store.get("ttl"), try store.entry("ttl")?.value)
        now = Date(timeIntervalSince1970: 111)
        XCTAssertEqual(try store.get("plain"), Data([2])) // even a plain read advances the clock clamp
        now = Date(timeIntervalSince1970: 101)
        XCTAssertNil(try store.get("ttl")); XCTAssertNil(try store.entry("ttl"))
        XCTAssertNil(try store.get("missing"))
        store.close()
        XCTAssertThrowsError(try store.get("plain"))
    }
}
