import Foundation

public struct BackupReport: Codable {
    public let destination: String
    public let sequence: UInt64
    public let bytes: Int64
}
extension KVStore {
    /// Blocks writes while copying; publishes a verified backup only after the copy completes.
    public func backup(to destination: URL) throws -> BackupReport {
        writerLock.lock(); defer { writerLock.unlock() }
        let source = try locked { try openFile() }
        try source.sync(durability == .fullSync ? .fullSync : .synchronized)
        locked { syncCount += 1 }
        return try Self.copyVerified(sourceDirectory: directory, destination: destination)
    }
    /// Restore into a NEW directory. Never overwrites an existing database or its backups.
    @discardableResult
    public static func restoreBackup(from backup: URL, to destination: URL) throws -> BackupReport {
        _ = try verify(directory: backup)
        return try copyVerified(sourceDirectory: backup, destination: destination)
    }
    static func copyVerified(sourceDirectory: URL, destination: URL) throws -> BackupReport {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw StoreError.destinationExists }
        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent)
        let staging = parent.appendingPathComponent(".strata-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let manifest = try Manifest.read(sourceDirectory)
            let names = (manifest?.files ?? ["store.log"]) + (manifest == nil ? [] : [Manifest.filename])
            for name in names {
                let output = staging.appendingPathComponent(name)
                try fm.copyItem(at: sourceDirectory.appendingPathComponent(name), to: output)
                try FileRef(output, writable: true).sync()
            }
            let report = try verify(directory: staging)
            try syncDirectory(staging)
            // moveItem fails if destination already exists; no destructive replacement.
            try fm.moveItem(at: staging, to: destination)
            try syncDirectory(parent)
            return BackupReport(destination: destination.path, sequence: report.sequence, bytes: report.fileBytes)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
