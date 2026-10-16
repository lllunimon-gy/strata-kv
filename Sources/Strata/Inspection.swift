import Foundation

extension KVStore {
    /// Read-only. No lock file creation, truncation, migration or directory cleanup.
    public static func inspect(directory: URL, includeFrames: Bool = false) throws -> InspectionReport {
        let file = try FileRef(directory.appendingPathComponent("store.log"))
        var frames: [FrameSummary] = []
        let state = try JournalCodec.scan(file, onFrame: includeFrames ? { frames.append($0) } : nil)
        let size = try file.size
        return InspectionReport(format: state.format, fileBytes: size, validBytes: state.validEnd,
                                incompleteTailBytes: size - state.validEnd, keys: state.index.count,
                                sequence: state.sequence, frameCount: state.frameCount,
                                maximumReadBytes: state.maximumRead, frames: frames)
    }
    public static func verify(directory: URL) throws -> InspectionReport {
        let report = try inspect(directory: directory)
        guard report.incompleteTailBytes == 0 else { throw StoreError.incompleteTail(bytes: report.incompleteTailBytes) }
        return report
    }
    /// Only repairs a validated v2 incomplete tail. Corrupt complete headers/frames are refused.
    public static func repairIncompleteTail(directory: URL) throws -> RepairReport {
        let lease = try DirectoryLease(directory)
        defer { withExtendedLifetime(lease) {} }
        let url = directory.appendingPathComponent("store.log")
        let file = try FileRef(url, writable: true)
        let state = try JournalCodec.scan(file)
        guard state.format == 2 else { throw StoreError.legacyFormat }
        let tail = try file.size - state.validEnd
        guard tail > 0 else { return RepairReport(backup: nil, removedTailBytes: 0, retainedBytes: state.validEnd) }
        let backup = directory.appendingPathComponent("repair-backup-\(UUID().uuidString).log")
        try FileManager.default.copyItem(at: url, to: backup)
        try FileRef(backup, writable: true).sync()
        try syncDirectory(directory)
        try file.truncate(to: state.validEnd)
        try file.sync()
        return RepairReport(backup: backup.lastPathComponent, removedTailBytes: tail, retainedBytes: state.validEnd)
    }
    @discardableResult
    public static func migrateLegacy(directory: URL, fault: ((WriteStage) throws -> Void)? = nil) throws -> String {
        let lease = try DirectoryLease(directory)
        defer { withExtendedLifetime(lease) {} }
        let url = directory.appendingPathComponent("store.log")
        let source = try FileRef(url)
        let original = try JournalCodec.scan(source)
        if original.format == 2 { return "already-v2" }
        let backup = directory.appendingPathComponent("legacy-backup-\(UUID().uuidString).log")
        try FileManager.default.copyItem(at: url, to: backup)
        try FileRef(backup, writable: true).sync()
        try syncDirectory(directory)
        let temporary = directory.appendingPathComponent("migration-\(UUID().uuidString).tmp")
        let output = try FileRef(temporary, writable: true)
        _ = try Rewriter.write(source: source, index: original.index, sequence: original.sequence, to: output)
        try fault?(.migrationReady)
        try replaceFile(temporary, url)
        try fault?(.migrationReplaced)
        return backup.lastPathComponent
    }
}
