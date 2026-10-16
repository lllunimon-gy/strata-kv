import Foundation
import Strata
import Darwin

func json<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(value), encoding: .utf8)!)
}
func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else {
        print("usage: strata-tool <inspect|verify|repair|migrate|benchmark|seed|check|crash|compact-crash> <directory> [stage]")
        exit(2)
    }
    let command = args[0], directory = URL(fileURLWithPath: args[1])
    let stage = args.count > 2 ? WriteStage(rawValue: args[2]) : nil
    // Diagnostic commands must not call the writable store initializer.
    switch command {
    case "inspect": try json(KVStore.inspect(directory: directory, includeFrames: true)); return
    case "verify": try json(KVStore.verify(directory: directory)); return
    case "repair": try json(KVStore.repairIncompleteTail(directory: directory)); return
    case "migrate": try json(["backup": KVStore.migrateLegacy(directory: directory)]); return
    case "benchmark": try json(runBenchmarks(directory: directory)); return
    case "migration-crash":
        guard let stage else { exit(2) }
        _ = try KVStore.migrateLegacy(directory: directory, fault: { if $0 == stage { _exit(86) } })
        return
    case "seed", "check", "crash", "compact-crash", "rotate-crash", "compact-delta-crash", "vacuum": break
    default: print("unknown command"); exit(2)
    }
    if command == "crash" || command == "compact-crash" { guard stage != nil else { exit(2) } }
    let store = try KVStore(directory: directory, segmentBytes: command == "rotate-crash" ? 128 : 4 * 1024 * 1024,
                            fault: { if $0 == stage { _exit(86) } })
    defer { store.close() }
    switch command {
    case "seed": try store.writeBatch([.put("a", Data("old".utf8)), .put("b", Data("old".utf8))])
    case "crash", "rotate-crash": try store.writeBatch([.put("a", Data("new".utf8)), .put("b", Data("new".utf8))])
    case "compact-crash": try store.compact()
    case "compact-delta-crash":
        try store.compact { progress in
            if case .captured = progress {
                do { try store.writeBatch([.put("a", Data("new".utf8)), .delete("b"), .put("c", Data("new".utf8))]) }
                catch { fputs("delta write failed: \(error)\n", stderr); exit(1) }
            }
        }
    case "vacuum": try json(store.vacuumOrphans())
    case "check":
        var values: [String: String] = [:]
        for key in try store.keys() { values[key] = try store.get(key).flatMap { String(data: $0, encoding: .utf8) } }
        try json(values)
    default: break
    }
}
do { try main() } catch { fputs("\(error)\n", stderr); exit(1) }
