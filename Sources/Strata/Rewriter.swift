import Foundation

enum Rewriter {
    static func write(source: FileRef, index: [String: Location], sequence: UInt64, to output: FileRef,
                      checkpoint: Bool = false, checkCancellation: () throws -> Void = {}) throws -> Recovery {
        try output.append(JournalCodec.fileHeader(baseSequence: sequence, checkpoint: checkpoint))
        var next = sequence
        var batch: [Mutation] = []
        var size = 0
        func emit() throws {
            guard !batch.isEmpty else { return }
            try checkCancellation()
            if !checkpoint {
                guard next < UInt64.max else { throw StoreError.invalidBatch }
                next += 1
            }
            let frame = try JournalCodec.encode(batch, sequence: next)
            try output.append(frame)
            batch.removeAll(keepingCapacity: true)
            size = 0
        }
        for key in index.keys.sorted() {
            guard let location = index[key] else { continue }
            let length = 25 + key.utf8.count + location.length
            if size + length > JournalCodec.maximumPayload || batch.count == JournalCodec.maximumOperations { try emit() }
            try checkCancellation()
            let data = try (location.source ?? source).read(at: location.offset, count: location.length)
            var mutation = Mutation.put(key, data)
            mutation.revision = location.revision
            mutation.expiration = location.expiration
            batch.append(mutation)
            size += length
        }
        try emit()
        try output.sync()
        return try JournalCodec.scan(output)
    }
}
