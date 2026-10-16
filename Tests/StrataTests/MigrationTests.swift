import XCTest
@testable import Strata

final class MigrationTests: XCTestCase {
    func fixture() -> Data {
        let payload = Data([1]) + JournalCodec.integer(1, width: 4) + JournalCodec.integer(3, width: 4) + Data("aold".utf8)
        let seq = JournalCodec.integer(1, width: 8), count = JournalCodec.integer(1, width: 4)
        let crc = JournalCodec.checksum(seq + count + payload)
        return Data("STRATA01BCH1".utf8) + JournalCodec.integer(UInt64(payload.count), width: 4)
            + seq + JournalCodec.integer(UInt64(crc), width: 4) + count + payload + Data("CMIT".utf8)
    }
    func testExplicitMigrationPreservesOriginalBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = fixture()
        try original.write(to: root.appendingPathComponent("store.log"))
        XCTAssertEqual(try KVStore.inspect(directory: root).format, 1)
        XCTAssertThrowsError(try KVStore(directory: root))
        let backup = try KVStore.migrateLegacy(directory: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backup)), original)
        XCTAssertEqual(try KVStore.verify(directory: root).format, 2)
        XCTAssertEqual(try KVStore(directory: root).get("a"), Data("old".utf8))
    }
    func testAmbiguousLegacyTailIsNeverSilentlyRepaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        var bytes = fixture()
        bytes.replaceSubrange(12..<16, with: JournalCodec.integer(4096, width: 4))
        let path = root.appendingPathComponent("store.log")
        try bytes.write(to: path)
        XCTAssertThrowsError(try KVStore.migrateLegacy(directory: root))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testMigrationInterruptionIsRestartable() throws {
        enum Fault: Error { case stop }
        for stage in [WriteStage.migrationReady, .migrationReplaced] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try ensureDirectory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            try fixture().write(to: root.appendingPathComponent("store.log"))
            XCTAssertThrowsError(try KVStore.migrateLegacy(directory: root, fault: { if $0 == stage { throw Fault.stop } }))
            _ = try KVStore.migrateLegacy(directory: root)
            XCTAssertEqual(try KVStore(directory: root).get("a"), Data("old".utf8))
        }
    }
}
