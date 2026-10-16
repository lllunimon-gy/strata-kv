import Foundation
import StrataObjC

struct Location { let offset: Int64; let length: Int }
public struct FrameSummary: Codable {
    public let sequence: UInt64
    public let offset: Int
    public let payloadBytes: Int
    public let operations: Int
}
struct Recovery {
    var index: [String: Location] = [:]
    var frames: [FrameSummary] = []
    var validEnd = 8
    var sequence: UInt64 = 0
}
struct EncodedFrame {
    let header: Data
    let payload: Data
    let trailer: Data
    let changes: [(key: String, relativeOffset: Int?, length: Int)]
    var count: Int { header.count + payload.count + trailer.count }
}
enum JournalCodec {
    static let magic = Data("STRATA01".utf8)
    static let maximumPayload = 16 * 1024 * 1024
    static let maximumValue = 8 * 1024 * 1024
    static let maximumOperations = 4096
    static func integer(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func number(_ data: Data, at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
    }
    static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { STCRC32($0.baseAddress, $0.count) } }
    static func encode(_ operations: [Mutation], sequence: UInt64) throws -> EncodedFrame {
        guard !operations.isEmpty, operations.count <= maximumOperations else { throw StoreError.invalidBatch }
        var payload = Data()
        var changes: [(key: String, relativeOffset: Int?, length: Int)] = []
        for operation in operations {
            let key = Data(operation.key.utf8)
            guard !key.isEmpty, key.count <= 1024 else { throw StoreError.invalidKey }
            let value = operation.value
            guard (value?.count ?? 0) <= maximumValue else { throw StoreError.valueTooLarge }
            guard payload.count + 9 + key.count + (value?.count ?? 0) <= maximumPayload else { throw StoreError.invalidBatch }
            payload.append(value == nil ? 2 : 1)
            payload.append(integer(UInt64(key.count), width: 4))
            payload.append(integer(UInt64(value?.count ?? 0), width: 4))
            payload.append(key)
            changes.append((operation.key, value == nil ? nil : payload.count, value?.count ?? 0))
            if let value { payload.append(value) }
        }
        let seq = integer(sequence, width: 8), count = integer(UInt64(operations.count), width: 4)
        let crc = checksum(seq + count + payload)
        let header = Data("BCH1".utf8) + integer(UInt64(payload.count), width: 4) + seq + integer(UInt64(crc), width: 4) + count
        return EncodedFrame(header: header, payload: payload, trailer: Data("CMIT".utf8), changes: changes)
    }
    static func replay(_ data: Data) throws -> Recovery {
        guard data.count >= 8, data.prefix(8) == magic else { throw StoreError.invalidHeader }
        var recovery = Recovery()
        var cursor = 8
        while cursor < data.count {
            guard data.count - cursor >= 24 else { break } // incomplete trailing header
            guard data.subdata(in: cursor..<cursor+4) == Data("BCH1".utf8) else { throw StoreError.corruption(offset: cursor) }
            let length = Int(number(data, at: cursor+4, width: 4))
            let sequence = number(data, at: cursor+8, width: 8)
            let crc = UInt32(number(data, at: cursor+16, width: 4))
            let count = Int(number(data, at: cursor+20, width: 4))
            guard length <= maximumPayload, count > 0, count <= maximumOperations, sequence == recovery.sequence + 1 else {
                throw StoreError.corruption(offset: cursor)
            }
            let end = cursor + 24 + length + 4
            guard end <= data.count else { break } // incomplete batch; no changes are visible
            guard data.subdata(in: end-4..<end) == Data("CMIT".utf8) else { throw StoreError.corruption(offset: cursor) }
            let payload = data.subdata(in: cursor+24..<end-4)
            guard checksum(integer(sequence, width: 8) + integer(UInt64(count), width: 4) + payload) == crc else {
                throw StoreError.corruption(offset: cursor)
            }
            var local = 0
            var changes: [(String, Location?)] = []
            for _ in 0..<count {
                guard payload.count - local >= 9 else { throw StoreError.corruption(offset: cursor + 24 + local) }
                let type = payload[local]
                let keyLength = Int(number(payload, at: local+1, width: 4))
                let valueLength = Int(number(payload, at: local+5, width: 4))
                local += 9
                guard keyLength > 0, keyLength <= 1024, valueLength <= maximumValue,
                      (type == 1 || type == 2), (type != 2 || valueLength == 0),
                      local + keyLength + valueLength <= payload.count,
                      let key = String(data: payload.subdata(in: local..<local+keyLength), encoding: .utf8) else {
                    throw StoreError.corruption(offset: cursor + 24 + local)
                }
                local += keyLength
                let location = type == 1 ? Location(offset: Int64(cursor + 24 + local), length: valueLength) : nil
                changes.append((key, location)); local += valueLength
            }
            guard local == payload.count else { throw StoreError.corruption(offset: cursor) }
            for (key, location) in changes { recovery.index[key] = location }
            recovery.frames.append(FrameSummary(sequence: sequence, offset: cursor, payloadBytes: length, operations: count))
            recovery.sequence = sequence; recovery.validEnd = end; cursor = end
        }
        return recovery
    }
}
