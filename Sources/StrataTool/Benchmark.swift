import Foundation
import Strata
import Darwin

struct Sample: Codable {
    let name: String
    let calls: Int
    let valueBytes: Int
    let batchSize: Int
    let durability: String
    let p50Microseconds: Double
    let p95Microseconds: Double
    let p99Microseconds: Double
    let totalSeconds: Double
    let statistics: StoreStatistics
}
struct BenchmarkReport: Codable {
    let version: String
    let operatingSystem: String
    let processors: Int
    let processPeakResidentBytes: Int64
    let note: String
    let samples: [Sample]
    let sqlite: [SQLiteSample]
}
func runBenchmarks(directory: URL) throws -> BenchmarkReport {
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw StoreError.destinationExists }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var results: [Sample] = []
    func sample(_ name: String, calls: Int, bytes: Int, batch: Int, mode: Durability,
                store: KVStore, operation: (Int) throws -> Void) throws {
        var latencies: [Double] = []
        for n in 0..<calls {
            let start = ProcessInfo.processInfo.systemUptime
            try operation(n)
            latencies.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let total = latencies.reduce(0, +)
        latencies.sort()
        func percentile(_ q: Double) -> Double { latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * q))] * 1_000_000 }
        results.append(Sample(name: name, calls: calls, valueBytes: bytes, batchSize: batch, durability: mode.rawValue,
                              p50Microseconds: percentile(0.50), p95Microseconds: percentile(0.95),
                              p99Microseconds: percentile(0.99), totalSeconds: total, statistics: try store.statistics()))
    }
    let single = try KVStore(directory: directory.appendingPathComponent("single"))
    try sample("single-sync-write", calls: 200, bytes: 256, batch: 1, mode: .synchronized, store: single) { n in
        try single.put("k\(n)", value: Data(repeating: 97, count: 256))
    }
    single.close()
    let batch = try KVStore(directory: directory.appendingPathComponent("batch"))
    try sample("batch-sync-write", calls: 200, bytes: 256, batch: 10, mode: .synchronized, store: batch) { n in
        try batch.writeBatch((0..<10).map { .put("k\(n*10+$0)", Data(repeating: 97, count: 256)) })
    }
    try sample("random-read-warm-cache", calls: 2000, bytes: 256, batch: 1, mode: .synchronized, store: batch) { n in
        _ = try batch.get("k\((n*7919)%2000)")
    }
    batch.close()
    let overwriteURL = directory.appendingPathComponent("overwrite")
    let overwrite = try KVStore(directory: overwriteURL, durability: .buffered)
    try sample("same-key-overwrite", calls: 2000, bytes: 256, batch: 1, mode: .buffered, store: overwrite) { _ in
        try overwrite.put("one", value: Data(repeating: 97, count: 256))
    }
    try overwrite.flush()
    overwrite.close()
    var recoveryTimes: [Double] = []
    for _ in 0..<10 {
        let start = ProcessInfo.processInfo.systemUptime
        let store = try KVStore(directory: overwriteURL)
        recoveryTimes.append(ProcessInfo.processInfo.systemUptime - start)
        store.close()
    }
    let recovered = try KVStore(directory: overwriteURL)
    let sorted = recoveryTimes.sorted()
    results.append(Sample(name: "reopen-warm-cache", calls: 10, valueBytes: 256, batchSize: 1, durability: "synchronized",
                          p50Microseconds: sorted[4]*1_000_000, p95Microseconds: sorted[8]*1_000_000,
                          p99Microseconds: sorted[8]*1_000_000, totalSeconds: sorted.reduce(0,+), statistics: try recovered.statistics()))
    try sample("compact-overwritten-log", calls: 1, bytes: 256, batch: 1, mode: .synchronized, store: recovered) { _ in try recovered.compact() }
    recovered.close()
    for bytes in [4096, 65536] {
        let store = try KVStore(directory: directory.appendingPathComponent("size-\(bytes)"))
        try sample("sync-write-\(bytes)-bytes", calls: 200, bytes: bytes, batch: 1, mode: .synchronized, store: store) { n in
            try store.put("k\(n)", value: Data(repeating: 97, count: bytes))
        }
        store.close()
    }
    let grouped = try KVStore(directory: directory.appendingPathComponent("grouped"))
    let writer = try GroupedWriter(store: grouped, maximumDelay: 0.01, maximumGroupRequests: 10)
    try sample("automatic-group-sync-write", calls: 200, bytes: 256, batch: 10, mode: .synchronized, store: grouped) { n in
        let group = DispatchGroup()
        let errorLock = NSLock()
        var failure: Error?
        for offset in 0..<10 {
            group.enter()
            writer.submit([.put("k\(n*10+offset)", Data(repeating: 97, count: 256))]) { result in
                if case .failure(let error) = result { errorLock.lock(); failure = error; errorLock.unlock() }
                group.leave()
            }
        }
        group.wait()
        if let failure { throw failure }
    }
    grouped.close()
    let sqlite = try [sqliteBenchmark(directory: directory.appendingPathComponent("sqlite-single"), calls: 200, batchSize: 1),
                      sqliteBenchmark(directory: directory.appendingPathComponent("sqlite-batch"), calls: 200, batchSize: 10)]
    var usage = rusage()
    _ = getrusage(RUSAGE_SELF, &usage)
    return BenchmarkReport(version: "0.4.1", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                           processors: ProcessInfo.processInfo.processorCount, processPeakResidentBytes: Int64(usage.ru_maxrss),
                           note: "Release build. Shared CI host; reads/reopens use warm OS cache. Batch latency is per batch, not per key. Peak RSS is for the whole process.", samples: results, sqlite: sqlite)
}
