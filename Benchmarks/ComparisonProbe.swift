// Copied unchanged into each revision's executable target by compare.py.
import Foundation
import Strata
import Darwin

struct Measurement: Codable {
    let name: String
    let samples: Int
    let p50Microseconds: Double
    let p95Microseconds: Double
    let p99Microseconds: Double
    let totalSeconds: Double
}
func monotonicNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func summarize(_ name: String, _ values: [UInt64]) -> Measurement {
    let sorted = values.sorted()
    func p(_ q: Double) -> Double { Double(sorted[Int(Double(sorted.count - 1) * q)]) / 1000 }
    return Measurement(name: name, samples: values.count, p50Microseconds: p(0.5), p95Microseconds: p(0.95),
                       p99Microseconds: p(0.99), totalSeconds: Double(values.reduce(0,+)) / 1e9)
}
func measure(_ name: String, count: Int, _ body: (Int) throws -> Void) rethrows -> Measurement {
    var times: [UInt64] = []; times.reserveCapacity(count)
    for n in 0..<count { let start = monotonicNanos(); try body(n); times.append(monotonicNanos() - start) }
    return summarize(name, times)
}
func run(_ root: URL) throws -> [Measurement] {
    guard !FileManager.default.fileExists(atPath: root.path) else { throw StoreError.destinationExists }
    var results: [Measurement] = []
    for mode in [Durability.synchronized, .buffered] {
        for batchSize in [1, 10] {
            let name = "\(mode.rawValue)-write-batch-\(batchSize)"
            let store = try KVStore(directory: root.appendingPathComponent(name), durability: mode)
            let count = mode == .buffered ? 3000 : 1000
            // Keep key/value construction outside the timed interval in all revisions.
            let requests = (0..<count).map { n in
                (0..<batchSize).map { Mutation.put("k\(n*batchSize+$0)", Data(repeating: 97, count: 256)) }
            }
            results.append(try measure(name, count: count) { try store.writeBatch(requests[$0]) })
            try store.flush(); store.close()
        }
    }
    let reads = try KVStore(directory: root.appendingPathComponent("reads"), durability: .buffered)
    for n in 0..<100 {
        try reads.writeBatch((0..<50).map { .put("k\(n*50+$0)", Data(repeating: 97, count: 256)) })
    }
    let keys = (0..<100000).map { "k\(($0*7919)%5000)" }
    var consumed = 0
    results.append(try measure("warm-read-256B", count: keys.count) { consumed += try reads.get(keys[$0])?.count ?? 0 })
    guard consumed == keys.count * 256 else { throw StoreError.invalidBatch }
#if STRATA_GROUPED
    consumed = 0
    results.append(try measure("warm-entry-256B", count: keys.count) { consumed += try reads.entry(keys[$0])?.value.count ?? 0 })
    guard consumed == keys.count * 256 else { throw StoreError.invalidBatch }
#endif
    reads.close()

    let reopenURL = root.appendingPathComponent("reopen")
    let seed = try KVStore(directory: reopenURL, durability: .buffered)
    for _ in 0..<3000 { try seed.put("a", value: Data(repeating: 97, count: 256)) }
    try seed.flush(); seed.close()
    results.append(try measure("warm-reopen-3000-frames", count: 15) { _ in
        let store = try KVStore(directory: reopenURL); store.close()
    })
    var compactTimes: [UInt64] = []
    for trial in 0..<10 {
        let store = try KVStore(directory: root.appendingPathComponent("compact-\(trial)"), durability: .buffered)
        for _ in 0..<1000 { try store.put("a", value: Data(repeating: 97, count: 256)) }
        try store.flush()
        let start = monotonicNanos(); try store.compact(); compactTimes.append(monotonicNanos() - start)
        guard try store.get("a")?.count == 256 else { throw StoreError.invalidBatch }
        store.close()
    }
    results.append(summarize("compact-1000-overwrites", compactTimes))
    let large = try KVStore(directory: root.appendingPathComponent("compact-live"), durability: .buffered)
    for n in 0..<100 {
        try large.writeBatch((0..<100).map { .put("k\(n*100+$0)", Data(repeating: 97, count: 256)) })
    }
    try large.flush()
    results.append(try measure("compact-10000-live-keys", count: 1) { _ in try large.compact() })
    guard try large.keys().count == 10000 else { throw StoreError.invalidBatch }
    large.close()

    // These callbacks intentionally select the staged fault path in all builds. They estimate
    // phase costs; normal writev-path performance is measured in the uninstrumented runs above.
    var marks: [UInt64] = []
    var phaseTimes = Array(repeating: [UInt64](), count: 5)
    let profile = try KVStore(directory: root.appendingPathComponent("phases"), fault: { stage in
        if [.afterHeader, .afterPayload, .afterCommit, .afterSync].contains(stage) { marks.append(monotonicNanos()) }
    })
    for n in 0..<1000 {
        let operations = (0..<10).map { Mutation.put("k\(n*10+$0)", Data(repeating: 97, count: 256)) }
        marks.removeAll(keepingCapacity: true)
        let start = monotonicNanos(); try profile.writeBatch(operations); let end = monotonicNanos()
        guard marks.count == 4 else { throw StoreError.invalidBatch }
        let points = [start] + marks + [end]
        for i in 0..<5 { phaseTimes[i].append(points[i+1] - points[i]) }
    }
    for (i, name) in ["encode-lock-header", "payload-write", "trailer-write", "sync", "publish"].enumerated() {
        results.append(summarize("instrumented-\(name)", phaseTimes[i]))
    }
    profile.close()
#if STRATA_GROUPED
    let grouped = try KVStore(directory: root.appendingPathComponent("grouped"))
    let writer = try GroupedWriter(store: grouped, maximumDelay: 0.01, maximumGroupRequests: 10)
    results.append(try measure("grouped-10-requests", count: 1000) { n in
        let group = DispatchGroup(); let lock = NSLock(); var failure: Error?
        for offset in 0..<10 {
            group.enter()
            writer.submit([.put("k\(n*10+offset)", Data(repeating: 97, count: 256))]) { result in
                if case .failure(let error) = result { lock.lock(); failure = error; lock.unlock() }
                group.leave()
            }
        }
        group.wait()
        if let failure { throw failure }
    })
    grouped.close()
#endif
    return results
}
do {
    let results = try run(URL(fileURLWithPath: CommandLine.arguments[1]))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print(String(data: try encoder.encode(results), encoding: .utf8)!)
} catch { fputs("\(error)\n", stderr); exit(1) }
