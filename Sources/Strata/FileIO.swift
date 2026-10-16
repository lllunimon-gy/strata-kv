import Foundation
import StrataObjC

func checkIO(_ code: Int32) throws {
    if code != 0 { throw StoreError.io(code) }
}
final class FileRef {
    let url: URL
    let name: String
    let descriptor: Int32
    init(_ url: URL, writable: Bool = false) throws {
        self.url = url
        self.name = url.lastPathComponent
        let opened = url.path.withCString { writable ? STOpen($0) : STOpenRead($0) }
        guard opened >= 0 else { throw StoreError.unsafeDirectory }
        guard STSize(opened) >= 0 else {
            STClose(opened)
            throw StoreError.unsafeDirectory
        }
        descriptor = opened
    }
    deinit { STClose(descriptor) }
    var size: Int64 { get throws {
        let size = STSize(descriptor)
        guard size >= 0 else { throw StoreError.io(5) }
        return size
    } }
    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw StoreError.invalidHeader }
        var data = Data(count: count)
        try checkIO(data.withUnsafeMutableBytes { STRead(descriptor, $0.baseAddress, $0.count, offset) })
        return data
    }
    func append(_ data: Data) throws {
        try checkIO(data.withUnsafeBytes { STWrite(descriptor, $0.baseAddress, $0.count) })
    }
    func append(_ frame: EncodedFrame) throws {
        try checkIO(frame.header.withUnsafeBytes { header in
            frame.payload.withUnsafeBytes { payload in
                frame.trailer.withUnsafeBytes { trailer in
                    STWriteFrame(descriptor, header.baseAddress, header.count,
                                 payload.baseAddress, payload.count, trailer.baseAddress, trailer.count)
                }
            }
        })
    }
    func sync(_ mode: Durability = .synchronized) throws {
        switch mode {
        case .buffered: break
        case .synchronized: try checkIO(STSync(descriptor))
        case .fullSync: try checkIO(STFullSync(descriptor))
        }
    }
    func truncate(to size: Int64) throws { try checkIO(STTruncate(descriptor, size)) }
}
final class DirectoryLease {
    private let descriptor: Int32
    init(_ root: URL) throws {
        descriptor = root.appendingPathComponent(".strata.lock").path.withCString { STLock($0) }
        guard descriptor >= 0 else { throw StoreError.directoryInUse }
    }
    deinit { STClose(descriptor) }
}
func ensureDirectory(_ url: URL) throws {
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw StoreError.unsafeDirectory
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}
func syncDirectory(_ url: URL) throws {
    try checkIO(url.path.withCString { STSyncDirectory($0) })
}
func replaceFile(_ source: URL, _ target: URL) throws {
    try checkIO(source.path.withCString { a in target.path.withCString { STRename(a, $0) } })
    try syncDirectory(target.deletingLastPathComponent())
}
