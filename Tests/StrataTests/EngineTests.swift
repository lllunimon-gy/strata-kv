import XCTest
@testable import Strata

final class EngineTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func testSegmentedModelSurvivesReopenAndCompaction() throws {
        let store = try KVStore(directory: root, durability: .buffered, segmentBytes: 256)
        var model: [String: Data] = [:]
        for n in 0..<200 {
            let key = "k\(n % 19)"
            if n % 4 == 0 { try store.delete(key); model[key] = nil }
            else { let value = Data("v\(n)".utf8); try store.put(key, value: value); model[key] = value }
        }
        XCTAssertGreaterThan(try store.statistics().segments, 10)
        store.close()
        let reopened = try KVStore(directory: root, segmentBytes: 256)
        XCTAssertEqual(try reopened.keys(), model.keys.sorted())
        for (key, value) in model { XCTAssertEqual(try reopened.get(key), value) }
        let revision = try reopened.statistics().sequence
        try reopened.compact()
        XCTAssertEqual(try reopened.statistics().segments, 2)
        XCTAssertEqual(try reopened.statistics().sequence, revision)
        try reopened.put("after", value: Data([7]))
        reopened.close()
        let final = try KVStore(directory: root)
        for (key, value) in model { XCTAssertEqual(try final.get(key), value) }
        XCTAssertEqual(try final.get("after"), Data([7]))
    }
    func testRotationFailureHasRecoverableManifest() throws {
        enum Stop: Error { case stop }
        for stage in [WriteStage.rotationReady, .rotationPublished] {
            let url = root.appendingPathComponent(stage.rawValue)
            let store = try KVStore(directory: url, segmentBytes: 128, fault: { if $0 == stage { throw Stop.stop } })
            try store.put("a", value: Data([1]))
            XCTAssertThrowsError(try store.put("b", value: Data([2])))
            store.close()
            let reopened = try KVStore(directory: url)
            XCTAssertEqual(try reopened.get("a"), Data([1]))
            XCTAssertNil(try reopened.get("b"))
            try reopened.put("c", value: Data([3]))
            XCTAssertEqual(try reopened.get("c"), Data([3]))
        }
    }
    func testSealedTailRefusedAndActiveTailRepairable() throws {
        let store = try KVStore(directory: root, segmentBytes: 128)
        try store.put("a", value: Data([1])); try store.put("b", value: Data([2])); store.close()
        let names = try XCTUnwrap(Manifest.read(root)).files
        let sealed = try FileRef(root.appendingPathComponent(names[0]), writable: true)
        let oldSize = try sealed.size
        try sealed.append(Data([0]))
        XCTAssertThrowsError(try KVStore(directory: root))
        XCTAssertThrowsError(try KVStore.repairIncompleteTail(directory: root))
        XCTAssertEqual(try sealed.size, oldSize + 1)
        try sealed.truncate(to: oldSize)
        let active = try FileRef(root.appendingPathComponent(names.last!), writable: true)
        try active.append(Data([0, 1]))
        XCTAssertEqual(try KVStore.inspect(directory: root).incompleteTailBytes, 2)
        XCTAssertEqual(try KVStore.repairIncompleteTail(directory: root).removedTailBytes, 2)
        XCTAssertEqual(try KVStore.verify(directory: root).keys, 2)
    }
    func testManifestChecksumAndUnsafeNamesAreRejected() throws {
        let store = try KVStore(directory: root); store.close()
        let url = root.appendingPathComponent(Manifest.filename)
        let good = try Data(contentsOf: url)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        let payload = try JSONEncoder().encode(Manifest(generation: 1, files: ["../outside.log"]))
        envelope["payload"] = payload.base64EncodedString()
        envelope["crc"] = JournalCodec.checksum(payload)
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        XCTAssertThrowsError(try KVStore(directory: root))
        envelope["crc"] = UInt32(0)
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        XCTAssertThrowsError(try KVStore.inspect(directory: root))
        try good.write(to: url)
        XCTAssertNoThrow(try KVStore(directory: root))
    }
    func testReadersSeeCommittedDataWhileWriterIsPaused() throws {
        let entered = expectation(description: "writer at partial frame")
        let finished = expectation(description: "writer completed")
        let readable = expectation(description: "read did not wait for writer")
        let release = DispatchSemaphore(value: 0)
        var pause = false
        let store = try KVStore(directory: root, fault: { stage in
            if pause && stage == .afterHeader { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        })
        try store.put("a", value: Data([1])); pause = true
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try store.put("a", value: Data([2])) } catch { XCTFail("\(error)") }
        }
        wait(for: [entered], timeout: 3)
        DispatchQueue.global().async {
            do { XCTAssertEqual(try store.get("a"), Data([1])) } catch { XCTFail("\(error)") }
            readable.fulfill()
        }
        wait(for: [readable], timeout: 2)
        release.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(try store.get("a"), Data([2]))
    }
    func testCompactionPreservesConcurrentUpdatesDeletesAndSnapshots() async throws {
        let store = try KVStore(directory: root, segmentBytes: 256)
        try store.writeBatch([.put("update", Data([1])), .put("delete", Data([2])), .put("keep", Data([3]))])
        let snapshot = try store.snapshot()
        let report = try await store.compactInBackground { stage in
            if case .captured = stage {
                do {
                    try store.put("update", value: Data([9]))
                    try store.delete("delete")
                    for n in 0..<10 { try store.put("new-\(n)", value: Data([UInt8(n)])) }
                    XCTAssertThrowsError(try store.compact())
                } catch { XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(report.capturedKeys, 3)
        XCTAssertTrue(report.cleanupFailures.isEmpty)
        XCTAssertEqual(try store.get("update"), Data([9])); XCTAssertNil(try store.get("delete"))
        XCTAssertEqual(try snapshot.get("update")?.value, Data([1]))
        XCTAssertEqual(try snapshot.get("delete")?.value, Data([2]))
        store.close()
        XCTAssertEqual(try snapshot.get("keep")?.value, Data([3]))
        let reopened = try KVStore(directory: root)
        XCTAssertEqual(try reopened.get("update"), Data([9])); XCTAssertNil(try reopened.get("delete"))
        XCTAssertEqual(try reopened.keys().count, 12)
    }
    func testCancelledCompactionLeavesUsableStore() async throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([1]))
        let captured = expectation(description: "captured")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await store.compactInBackground { progress in
                if case .captured = progress { captured.fulfill(); _ = release.wait(timeout: .now() + 5) }
            }
        }
        await fulfillment(of: [captured], timeout: 3)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try store.put("b", value: Data([2]))
        store.close()
        XCTAssertEqual(try KVStore(directory: root).keys(), ["a", "b"])
    }
    func testCloseDuringCompactionRetainsLeaseUntilWorkerExits() async throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([1]))
        do {
            _ = try await store.compactInBackground { progress in
                if case .captured = progress {
                    store.close()
                    XCTAssertThrowsError(try KVStore(directory: self.root))
                }
            }
            XCTFail("closed store cannot publish")
        } catch { XCTAssertEqual(error as? StoreError, .closed) }
        XCTAssertEqual(try KVStore(directory: root).get("a"), Data([1]))
    }
    func testSegmentedBackupIncludesCheckpointAndDelta() throws {
        let store = try KVStore(directory: root.appendingPathComponent("source"), segmentBytes: 128)
        for n in 0..<10 { try store.put("k\(n)", value: Data([UInt8(n)])) }
        try store.compact()
        try store.delete("k1"); try store.put("k2", value: Data([99]))
        let backup = root.appendingPathComponent("backup")
        _ = try store.backup(to: backup)
        try store.delete("k3")
        let restored = root.appendingPathComponent("restored")
        _ = try KVStore.restoreBackup(from: backup, to: restored)
        let copy = try KVStore(directory: restored)
        XCTAssertNil(try copy.get("k1")); XCTAssertEqual(try copy.get("k2"), Data([99]))
        XCTAssertEqual(try copy.get("k3"), Data([3]))
    }
    func testVacuumOnlyRemovesRecognizedOrphans() throws {
        let store = try KVStore(directory: root)
        let orphan = "segment-\(UUID().uuidString).log"
        for name in [orphan, "segment-not-owned.log", "repair-backup-example.log", "notes.txt"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(try store.vacuumOrphans(), [orphan])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("repair-backup-example.log").path))
        XCTAssertNoThrow(try KVStore.verify(directory: root))
    }
    func testGroupedWriterCoalescesAndRejectsInvalidRequestIndependently() async throws {
        let store = try KVStore(directory: root)
        let writer = try GroupedWriter(store: store, maximumDelay: 1, maximumGroupRequests: 20)
        let done = expectation(description: "all callbacks"); done.expectedFulfillmentCount = 20
        for n in 0..<20 {
            writer.submit([.put("k\(n)", Data([UInt8(n)]))]) { result in
                if case .failure(let error) = result { XCTFail("\(error)") }; done.fulfill()
            }
        }
        let bad = expectation(description: "invalid request")
        writer.submit([.put("", Data())]) { result in
            if case .success = result { XCTFail("invalid key accepted") }; bad.fulfill()
        }
        await fulfillment(of: [done, bad], timeout: 3)
        XCTAssertEqual(try store.statistics().frameCount, 1)
        XCTAssertEqual(try store.statistics().syncCount, 2) // initial header + one group
        try await writer.close()
        do { try await writer.writeBatch([.put("late", Data())]); XCTFail("closed writer") }
        catch { XCTAssertEqual(error as? StoreError, .closed) }
        XCTAssertEqual(try store.keys().count, 20)
    }
    func testGroupAdmissionIsBoundedAndCloseDrainsAcceptedWrites() async throws {
        let store = try KVStore(directory: root)
        let writer = try GroupedWriter(store: store, maximumDelay: 1, maximumPendingBytes: 100, maximumPendingRequests: 1)
        let accepted = expectation(description: "accepted")
        writer.submit([.put("a", Data([1]))]) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }; accepted.fulfill()
        }
        let refused = expectation(description: "backpressure")
        writer.submit([.put("b", Data([2]))]) { result in
            if case .failure(let error) = result { XCTAssertEqual(error as? StoreError, .queueFull) }
            else { XCTFail("queue not bounded") }; refused.fulfill()
        }
        try await writer.close()
        await fulfillment(of: [accepted, refused], timeout: 3)
        XCTAssertEqual(try store.get("a"), Data([1])); XCTAssertNil(try store.get("b"))
    }
    func testGroupedFailureResolvesEveryWaiter() async throws {
        enum Stop: Error { case stop }
        let store = try KVStore(directory: root, fault: { if $0 == .afterPayload { throw Stop.stop } })
        let writer = try GroupedWriter(store: store, maximumDelay: 1, maximumGroupRequests: 5)
        let done = expectation(description: "all failed"); done.expectedFulfillmentCount = 5
        for n in 0..<5 {
            writer.submit([.put("k\(n)", Data([1]))]) { result in
                if case .success = result { XCTFail("partial write acknowledged") }; done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 3)
        store.close()
        XCTAssertEqual(try KVStore(directory: root).keys(), [])
    }
    func testCheckpointFlagsAndFramesAreChecksummed() throws {
        let store = try KVStore(directory: root)
        try store.put("a", value: Data([1])); try store.compact(); store.close()
        let name = try XCTUnwrap(Manifest.read(root)).files[0]
        let url = root.appendingPathComponent(name)
        var bytes = try Data(contentsOf: url)
        bytes[20] = 0
        try bytes.write(to: url)
        XCTAssertThrowsError(try KVStore(directory: root))
    }
}
