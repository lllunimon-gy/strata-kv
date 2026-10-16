import Foundation

enum Rewriter {
    static func write(source: FileRef, index: [String: Location], sequence: UInt64, to output: FileRef) throws -> Recovery {
        try output.append(JournalCodec.fileHeader(baseSequence: sequence))
        var next = sequence
        var batch: [Mutation] = []
        var size = 0
        func emit() throws {
            guard !batch.isEmpty else { return }
            guard next < UInt64.max else { throw StoreError.invalidBatch }
            next += 1
            let frame = try JournalCodec.encode(batch, sequence: next)
            try output.append(frame.header)
            try output.append(frame.payload)
            try output.append(frame.trailer)
            batch.removeAll(keepingCapacity: true)
            size = 0
        }
        for key in index.keys.sorted() {
            guard let location = index[key] else { continue }
            let length = 25 + key.utf8.count + location.length
            if size + length > JournalCodec.maximumPayload || batch.count == JournalCodec.maximumOperations { try emit() }
            let data = try source.read(at: location.offset, count: location.length)
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
