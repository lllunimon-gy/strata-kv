import Foundation

/// Read-only v1 support. Ambiguous legacy tails require strict failure, never automatic truncation.
enum LegacyReader {
    static func scan(_ file: FileRef, onFrame: ((FrameSummary) -> Void)?) throws -> Recovery {
        let size = try file.size
        var result = Recovery()
        result.format = 1
        result.validEnd = 8
        var cursor: Int64 = 8
        while cursor < size {
            guard size - cursor >= 24 else { throw StoreError.incompleteTail(bytes: size - cursor) }
            let header = try file.read(at: cursor, count: 24)
            let length = Int(JournalCodec.number(header, at: 4, width: 4))
            let sequence = JournalCodec.number(header, at: 8, width: 8)
            let crc = UInt32(JournalCodec.number(header, at: 16, width: 4))
            let count = Int(JournalCodec.number(header, at: 20, width: 4))
            guard header.prefix(4) == Data("BCH1".utf8), length <= JournalCodec.maximumPayload,
                  count > 0, count <= JournalCodec.maximumOperations, sequence == result.sequence + 1 else {
                throw StoreError.corruption(offset: cursor)
            }
            let end = cursor + 24 + Int64(length) + 4
            guard end <= size else { throw StoreError.incompleteTail(bytes: size - cursor) }
            let payload = try file.read(at: cursor + 24, count: length)
            let trailer = try file.read(at: end - 4, count: 4)
            let checked = JournalCodec.integer(sequence, width: 8) + JournalCodec.integer(UInt64(count), width: 4) + payload
            guard JournalCodec.checksum(checked) == crc, trailer == Data("CMIT".utf8) else {
                throw StoreError.corruption(offset: cursor)
            }
            var local = 0
            for _ in 0..<count {
                guard payload.count - local >= 9 else { throw StoreError.corruption(offset: cursor) }
                let type = payload[local]
                let keyCount = Int(JournalCodec.number(payload, at: local + 1, width: 4))
                let valueCount = Int(JournalCodec.number(payload, at: local + 5, width: 4))
                local += 9
                guard (type == 1 || type == 2), keyCount > 0, keyCount <= 1024,
                      valueCount <= JournalCodec.maximumValue, (type != 2 || valueCount == 0),
                      local + keyCount + valueCount <= payload.count,
                      let key = String(data: payload.subdata(in: local..<local+keyCount), encoding: .utf8) else {
                    throw StoreError.corruption(offset: cursor)
                }
                local += keyCount
                result.index[key] = type == 1 ? Location(offset: cursor + 24 + Int64(local), length: valueCount,
                                                        revision: sequence, expiration: nil, source: file) : nil
                local += valueCount
            }
            guard local == payload.count else { throw StoreError.corruption(offset: cursor) }
            result.validEnd = end
            result.sequence = sequence
            result.frameCount += 1
            result.maximumRead = max(result.maximumRead, max(length, 24))
            onFrame?(FrameSummary(sequence: sequence, offset: cursor, payloadBytes: length, operations: count))
            cursor = end
        }
        return result
    }
}
