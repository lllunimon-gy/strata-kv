import Foundation

public enum StoreError: Error, Equatable {
    case directoryInUse, unsafeDirectory, invalidHeader, legacyFormat
    case corruption(offset: Int64), incompleteTail(bytes: Int64)
    case invalidKey, invalidBatch, valueTooLarge, invalidExpiration
    case io(Int32), closed, requiresReopen, destinationExists
}
public enum Durability: String, Codable { case buffered, synchronized, fullSync }
public enum RecoveryPolicy { case strict, recoverIncompleteTail }
public enum WriteStage: String {
    case afterHeader, afterPayload, afterCommit, afterSync
    case compactionReady, compactionReplaced, migrationReady, migrationReplaced
}
public struct Mutation {
    public let key: String
    public let value: Data?
    var revision: UInt64? = nil
    var expiration: Double? = nil
    public static func put(_ key: String, _ value: Data) -> Mutation { Mutation(key: key, value: value) }
    public static func delete(_ key: String) -> Mutation { Mutation(key: key, value: nil) }
}
public struct FrameSummary: Codable {
    public let sequence: UInt64
    public let offset: Int64
    public let payloadBytes: Int
    public let operations: Int
}
public struct StoreStatistics: Codable {
    public let keys: Int
    public let logBytes: Int64
    public let sequence: UInt64
    public let recoveredTailBytes: Int64
    public let frameCount: Int
    public let liveValueBytes: Int64
    public let syncCount: Int
    public let recoveryBufferBytes: Int
}
public struct InspectionReport: Codable {
    public let format: Int
    public let fileBytes: Int64
    public let validBytes: Int64
    public let incompleteTailBytes: Int64
    public let keys: Int
    public let sequence: UInt64
    public let frameCount: Int
    public let maximumReadBytes: Int
    public let frames: [FrameSummary]
}
public struct RepairReport: Codable {
    public let backup: String?
    public let removedTailBytes: Int64
    public let retainedBytes: Int64
}
struct Location {
    let offset: Int64
    let length: Int
    let revision: UInt64
    let expiration: Double?
}
struct Recovery {
    var index: [String: Location] = [:]
    var validEnd: Int64 = 24
    var sequence: UInt64 = 0
    var frameCount = 0
    var maximumRead = 0
    var format = 2
}
