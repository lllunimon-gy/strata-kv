import Foundation

struct Manifest: Codable {
    let generation: UInt64
    let files: [String]
    private struct Envelope: Codable { let payload: Data; let crc: UInt32 }
    static let filename = "manifest.json"
    static func validName(_ name: String) -> Bool {
        if name == "store.log" { return true }
        guard name.hasPrefix("segment-"), name.hasSuffix(".log") else { return false }
        return UUID(uuidString: String(name.dropFirst(8).dropLast(4))) != nil
    }
    static func read(_ root: URL) throws -> Manifest? {
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try FileRef(url)
        let size = try file.size
        guard size > 0, size <= 1024 * 1024 else { throw StoreError.invalidManifest }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: file.read(at: 0, count: Int(size)))
            guard JournalCodec.checksum(envelope.payload) == envelope.crc else { throw StoreError.invalidManifest }
            let manifest = try JSONDecoder().decode(Manifest.self, from: envelope.payload)
            guard !manifest.files.isEmpty, manifest.files.count <= 8192,
                  Set(manifest.files).count == manifest.files.count,
                  manifest.files.allSatisfy(validName) else { throw StoreError.invalidManifest }
            return manifest
        } catch { throw StoreError.invalidManifest }
    }
    func publish(_ root: URL, durability: Durability = .synchronized) throws {
        guard !files.isEmpty, files.count <= 8192, files.allSatisfy(Self.validName),
              Set(files).count == files.count else { throw StoreError.invalidManifest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        let data = try encoder.encode(Envelope(payload: payload, crc: JournalCodec.checksum(payload)))
        guard data.count <= 1024 * 1024 else { throw StoreError.invalidManifest }
        let temporary = root.appendingPathComponent("manifest-\(UUID().uuidString).tmp")
        let output = try FileRef(temporary, writable: true)
        try output.append(data)
        try output.sync(durability == .fullSync ? .fullSync : .synchronized)
        try replaceFile(temporary, root.appendingPathComponent(Self.filename))
    }
}
struct JournalSet {
    let manifest: Manifest?
    let files: [FileRef]
    let state: Recovery
    let bytes: Int64
    let tail: Int64
    static func load(_ root: URL, onFrame: ((FrameSummary) -> Void)? = nil) throws -> JournalSet {
        let manifest = try Manifest.read(root)
        let names = manifest?.files ?? ["store.log"]
        var files: [FileRef] = [], combined = Recovery(), bytes: Int64 = 0, tail: Int64 = 0
        for (position, name) in names.enumerated() {
            let file = try FileRef(root.appendingPathComponent(name))
            let state = try JournalCodec.scan(file, onFrame: onFrame)
            let size = try file.size
            guard position == 0 || (state.format == 2 && !state.checkpoint && state.baseSequence == combined.sequence) else {
                throw StoreError.invalidManifest
            }
            guard position == names.count - 1 || state.validEnd == size else {
                throw StoreError.incompleteTail(bytes: size - state.validEnd)
            }
            if manifest != nil, state.format != 2 { throw StoreError.legacyFormat }
            for key in state.deleted { combined.index[key] = nil }
            combined.index.merge(state.index) { _, new in new }
            combined.validEnd = state.validEnd
            combined.sequence = state.sequence
            combined.frameCount += state.frameCount
            combined.maximumRead = max(combined.maximumRead, state.maximumRead)
            combined.format = state.format
            combined.checkpoint = state.checkpoint
            bytes += size
            tail = size - state.validEnd
            files.append(file)
        }
        return JournalSet(manifest: manifest, files: files, state: combined, bytes: bytes, tail: tail)
    }
}
