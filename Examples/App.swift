import SwiftUI
import Strata

@main struct StrataExample: App { var body: some Scene { WindowGroup { ContentView() } } }
struct ContentView: View {
    @State private var message = "打开后写入一组数据，重启验证，再执行压缩"
    @State private var busy = false
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StrataExample")
    var body: some View {
        NavigationView { List {
            Text(message).textSelection(.enabled)
            Button("批量写入两个 key") { run { store in
                try store.writeBatch([.put("reader", Data("gy".utf8)), .put("theme", Data("dark".utf8))])
                return "批次已同步提交"
            }}
            Button("读取") { run { store in
                try store.keys().map { key in
                    let value = try store.get(key).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return "\(key) = \(value)"
                }.joined(separator: "\n")
            }}
            Button("覆盖 100 次并压缩") { run { store in
                for n in 0..<100 { try store.put("counter", value: Data("\(n)".utf8)) }
                let before = try store.statistics().logBytes
                try store.compact()
                return "日志 \(before) → \(try store.statistics().logBytes) B"
            }}
            Button("删除 theme") { run { store in try store.delete("theme"); return "已删除" } }
        }.disabled(busy).navigationTitle("Strata · gy") }
    }
    private func run(_ operation: @escaping (KVStore) throws -> String) {
        busy = true; let directory = directory
        Task {
            let result = await Task.detached { () -> String in
                do {
                    let store = try KVStore(directory: directory); defer { store.close() }
                    return try operation(store)
                } catch { return String(describing: error) }
            }.value
            message = result; busy = false
        }
    }
}
