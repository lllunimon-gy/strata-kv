import Foundation
import Strata
import Darwin

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else {
        print("usage: strata-tool <seed|inspect|crash|compact-crash|check|benchmark> <directory> [stage]")
        exit(2)
    }
    let command = args[0], directory = URL(fileURLWithPath: args[1])
    let stage = args.count > 2 ? WriteStage(rawValue: args[2]) : nil
    if command == "crash" || command == "compact-crash" {
        guard stage != nil else { print("valid stage required"); exit(2) }
    }
    let store = try KVStore(directory: directory, fault: { point in
        if point == stage { _exit(86) } // Real process termination, no deinit/close.
    })
    defer { store.close() }
    switch command {
    case "seed": try store.writeBatch([.put("a", Data("old".utf8)), .put("b", Data("old".utf8))])
    case "crash": try store.writeBatch([.put("a", Data("new".utf8)), .put("b", Data("new".utf8))])
    case "compact-crash": try store.compact()
    case "check":
        var output: [String: String] = [:]
        for key in try store.keys() { output[key] = try store.get(key).flatMap { String(data: $0, encoding: .utf8) } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(data: try encoder.encode(output), encoding: .utf8)!)
    case "inspect":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(store.frames()), encoding: .utf8)!)
        print("keys=\(try store.statistics().keys), logBytes=\(try store.statistics().logBytes)")
    case "benchmark":
        let start = ProcessInfo.processInfo.systemUptime
        let value = Data(repeating: 0x61, count: 256)
        for batch in 0..<100 {
            try store.writeBatch((0..<10).map { .put("\(batch * 10 + $0)", value) })
        }
        let writeTime = ProcessInfo.processInfo.systemUptime - start
        let readStart = ProcessInfo.processInfo.systemUptime
        for n in 0..<1000 { _ = try store.get("\(n)") }
        print("mode=synchronized,batch=10,keys=1000,valueBytes=256,writeSeconds=\(writeTime),readSeconds=\(ProcessInfo.processInfo.systemUptime-readStart)")
    default: print("unknown command"); exit(2)
    }
}
do { try main() } catch { fputs("\(error)\n", stderr); exit(1) }
