import Foundation
import StrataObjC

struct EncodedFrame {
    let header: Data
    let payload: Data
    let trailer: Data
    let changes: [(key: String, offset: Int?, length: Int, revision: UInt64, expiration: Double?)]
    var count: Int { header.count + payload.count + trailer.count }
}
enum JournalCodec {
    static let headerSize = 24
    static let frameHeaderSize = 28
    static let maximumPayload = 16 * 1024 * 1024
    static let maximumValue = 8 * 1024 * 1024
    static let maximumOperations = 4096
    static func integer(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func number(_ data: Data, at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
    }
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { STCRC32($0.baseAddress, $0.count) }
    }
    static func fileHeader(baseSequence: UInt64 = 0, checkpoint: Bool = false) -> Data {
        let base = Data("STRATA02".utf8) + integer(baseSequence, width: 8)
        let flags = integer(checkpoint ? 1 : 0, width: 4)
        let checked = checkpoint ? base + flags : base
        return base + integer(UInt64(checksum(checked)), width: 4) + flags
    }
    static func encode(_ operations: [Mutation], sequence: UInt64) throws -> EncodedFrame {
        guard sequence > 0, !operations.isEmpty, operations.count <= maximumOperations else { throw StoreError.invalidBatch }
        var payload = Data()
        var changes: [(key: String, offset: Int?, length: Int, revision: UInt64, expiration: Double?)] = []
        for operation in operations {
            let key = Data(operation.key.utf8)
            guard !key.isEmpty, key.count <= 1024 else { throw StoreError.invalidKey }
            let value = operation.value
            let revision = operation.revision ?? sequence
            guard revision > 0, revision <= sequence else { throw StoreError.invalidBatch }
            if let expiration = operation.expiration {
                guard expiration.isFinite, value != nil else { throw StoreError.invalidExpiration }
            }
            guard (value?.count ?? 0) <= maximumValue else { throw StoreError.valueTooLarge }
            guard payload.count + 25 + key.count + (value?.count ?? 0) <= maximumPayload else { throw StoreError.invalidBatch }
            payload.append(value == nil ? 2 : operation.expiration == nil ? 1 : 129)
            payload.append(integer(UInt64(key.count), width: 4))
            payload.append(integer(UInt64(value?.count ?? 0), width: 4))
            payload.append(integer(revision, width: 8))
            payload.append(integer(operation.expiration?.bitPattern ?? 0, width: 8))
            payload.append(key)
            changes.append((operation.key, value == nil ? nil : payload.count, value?.count ?? 0, revision, operation.expiration))
            if let value { payload.append(value) }
        }
        let head = Data("BCH2".utf8) + integer(UInt64(payload.count), width: 4)
            + integer(sequence, width: 8) + integer(UInt64(operations.count), width: 4)
            + integer(UInt64(checksum(payload)), width: 4)
        let commit = Data("CMT2".utf8) + integer(sequence, width: 8)
        return EncodedFrame(header: head + integer(UInt64(checksum(head)), width: 4), payload: payload,
                            trailer: commit + integer(UInt64(checksum(commit)), width: 4), changes: changes)
    }
    /// One bounded payload allocation at a time; summaries are delivered only when requested.
    static func scan(_ file: FileRef, onFrame: ((FrameSummary) -> Void)? = nil) throws -> Recovery {
        let size = try file.size
        guard size >= 8 else { throw StoreError.invalidHeader }
        let magic = try file.read(at: 0, count: 8)
        if magic == Data("STRATA01".utf8) { return try LegacyReader.scan(file, onFrame: onFrame) }
        guard magic == Data("STRATA02".utf8), size >= 24 else { throw StoreError.invalidHeader }
        let fileHeader = try file.read(at: 0, count: 24)
        let flags = number(fileHeader, at: 20, width: 4)
        let checked = fileHeader.subdata(in: 0..<16) + (flags == 1 ? fileHeader.suffix(4) : Data())
        guard flags <= 1, checksum(checked) == UInt32(number(fileHeader, at: 16, width: 4)) else {
            throw StoreError.invalidHeader
        }
        var recovery = Recovery()
        recovery.sequence = number(fileHeader, at: 8, width: 8)
        recovery.baseSequence = recovery.sequence
        recovery.checkpoint = flags == 1
        recovery.maximumRead = 24
        var cursor: Int64 = 24
        while cursor < size {
            guard size - cursor >= 28 else { break }
            let header = try file.read(at: cursor, count: 28)
            // Validate the fixed header BEFORE using its untrusted length.
            guard header.prefix(4) == Data("BCH2".utf8),
                  checksum(header.subdata(in: 0..<24)) == UInt32(number(header, at: 24, width: 4)) else {
                throw StoreError.corruption(offset: cursor)
            }
            let length = Int(number(header, at: 4, width: 4))
            let sequence = number(header, at: 8, width: 8)
            let count = Int(number(header, at: 16, width: 4))
            let crc = UInt32(number(header, at: 20, width: 4))
            guard length <= maximumPayload, count > 0, count <= maximumOperations,
                  sequence > 0, (recovery.checkpoint ? sequence == recovery.baseSequence :
                    recovery.sequence < UInt64.max && sequence == recovery.sequence + 1) else {
                throw StoreError.corruption(offset: cursor)
            }
            let end = cursor + 28 + Int64(length) + 16
            guard end <= size else { break }
            let body = try file.read(at: cursor + 28, count: length)
            let trailer = try file.read(at: end - 16, count: 16)
            recovery.maximumRead = max(recovery.maximumRead, max(length, 28))
            guard checksum(body) == crc, trailer.prefix(4) == Data("CMT2".utf8),
                  number(trailer, at: 4, width: 8) == sequence,
                  checksum(trailer.subdata(in: 0..<12)) == UInt32(number(trailer, at: 12, width: 4)) else {
                throw StoreError.corruption(offset: cursor)
            }
            var local = 0
            var changes: [(String, Location?)] = []
            for _ in 0..<count {
                guard body.count - local >= 25 else { throw StoreError.corruption(offset: cursor) }
                let type = body[local]
                let keyLength = Int(number(body, at: local + 1, width: 4))
                let valueLength = Int(number(body, at: local + 5, width: 4))
                let revision = number(body, at: local + 9, width: 8)
                let expirationBits = number(body, at: local + 17, width: 8)
                let expiration = type == 129 ? Double(bitPattern: expirationBits) : nil
                local += 25
                guard [UInt8(1), 2, 129].contains(type), keyLength > 0, keyLength <= 1024,
                      valueLength <= maximumValue, revision > 0, revision <= sequence,
                      (type != 2 || valueLength == 0), (type == 129 || expirationBits == 0),
                      (expiration?.isFinite ?? true), local + keyLength + valueLength <= body.count,
                      let key = String(data: body.subdata(in: local..<local+keyLength), encoding: .utf8) else {
                    throw StoreError.corruption(offset: cursor + 28 + Int64(local))
                }
                local += keyLength
                let location = type == 2 ? nil : Location(offset: cursor + 28 + Int64(local), length: valueLength,
                                                          revision: revision, expiration: expiration, source: file)
                changes.append((key, location))
                local += valueLength
            }
            guard local == body.count else { throw StoreError.corruption(offset: cursor) }
            for (key, location) in changes {
                recovery.index[key] = location
                if location == nil { recovery.deleted.insert(key) } else { recovery.deleted.remove(key) }
            }
            onFrame?(FrameSummary(sequence: sequence, offset: cursor, payloadBytes: length, operations: count, segment: file.url.lastPathComponent))
            recovery.sequence = sequence
            recovery.validEnd = end
            recovery.frameCount += 1
            cursor = end
        }
        return recovery
    }
}
