import SwiftUI
import Strata

@main struct StrataExample: App { var body: some Scene { WindowGroup { ContentView() } } }
struct Article: Codable { let title: String; var readProgress: Double }
private struct LegacyArticle: Codable { let title: String; let progress: Double }
private let articleKey = CodableKey<Article>("current", schemaVersion: 2, migrations: [1: { data in
    let old = try JSONDecoder().decode(LegacyArticle.self, from: data)
    return try JSONEncoder().encode(Article(title: old.title, readProgress: old.progress))
}])
struct ContentView: View {
    @State private var message = "先保存示例文章，再试阅读进度、过期草稿和备份。关闭 App 后数据仍在。"
    @State private var title = "尚无离线文章"
    @State private var progress = 0.0
    @State private var summary = "尚未打开数据库"
    @State private var busy = false
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StrataReader")
    var body: some View {
        NavigationView { List {
            Section("离线阅读") {
                Text(title).font(.headline)
                ProgressView(value: progress)
                Button("保存文章") { run { store in
                    try store.namespace("articles").set(Article(title: "一次提交的边界", readProgress: 0), for: articleKey)
                    return "已保存。退出后重新打开，验证离线读取。"
                }}
                Button("阅读进度增加 25%") { run { store in
                    let library = try store.namespace("articles")
                    guard var article = try library.read(articleKey)?.value else { return "请先保存文章。" }
                    article.readProgress = min(1, article.readProgress + 0.25)
                    try library.set(article, for: articleKey)
                    return "阅读进度已保存。"
                }}
                Button("刷新离线数据") { run { _ in "已从磁盘读取。" } }
            }
            Section("数据演进") {
                Button("写入旧模型，再迁移读取") { run { store in
                    let library = try store.namespace("articles")
                    try library.set(LegacyArticle(title: "从 progress 到 readProgress", progress: 0.5),
                                    for: CodableKey<LegacyArticle>("current", schemaVersion: 1))
                    let result = try library.read(articleKey)
                    return "迁移完成：\(result?.migrated == true ? "旧模型已升级" : "无需升级")。"
                }}
                Button("保存 10 秒草稿") { run { store in
                    try store.namespace("drafts").put("note", value: Data("读到第三段".utf8), ttl: 10)
                    return "草稿将在 10 秒后不可读；空间由压缩回收。"
                }}
                Button("查看草稿") { run { store in
                    let data = try store.namespace("drafts").get("note")
                    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "草稿不存在或已过期。"
                }}
                Button("模拟旧版本覆盖冲突") { run { store in
                    let positions = try store.namespace("positions")
                    try positions.put("cursor", value: Data("first".utf8))
                    guard let old = try positions.entry("cursor") else { return "没有阅读位置。" }
                    try positions.put("cursor", value: Data("newer".utf8))
                    let result = try positions.compareExchange("cursor", expectedRevision: old.revision, value: Data("stale".utf8))
                    if case .conflict = result { return "旧版本被拒绝，较新的阅读位置仍然保留。" }
                    return "比较更新成功。"
                }}
            }
            Section("维护与观察") {
                Button("自动合批保存 100 个书签") { run { store in
                    let bookmarks = try store.namespace("bookmarks")
                    let writer = try GroupedWriter(store: store)
                    let before = try store.statistics().syncCount
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for n in 0..<100 {
                            let operation = try bookmarks.putMutation("page-\(n)", value: Data("bookmark".utf8))
                            group.addTask { try await writer.writeBatch([operation]) }
                        }
                        try await group.waitForAll()
                    }
                    try await writer.close()
                    return "100 个书签已完成；日志同步 \(try store.statistics().syncCount - before) 次（包含最后 flush）。"
                }}
                Button("固定快照，分页读取书签") { run { store in
                    let snapshot = try store.namespace("bookmarks").snapshot()
                    let first = try snapshot.page(prefix: "page-", limit: 8)
                    return "快照第一页：\(first.entries.map(\.key).joined(separator: ", "))。后续写入不会改变这份快照。"
                }}
                Button("后台整理过期和旧版本数据") { run { store in
                    let before = try store.statistics().logBytes
                    let report = try await store.compactInBackground()
                    return "日志 \(before) → \(try store.statistics().logBytes) B；退役 \(report.retiredSegments) 个文件。"
                }}
                Button("创建备份，并恢复到新目录验证") { run { store in
                    let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let suffix = UUID().uuidString
                    let backup = parent.appendingPathComponent("ReaderBackup-\(suffix)")
                    let restored = parent.appendingPathComponent("ReaderRestored-\(suffix)")
                    let report = try store.backup(to: backup)
                    _ = try KVStore.restoreBackup(from: backup, to: restored)
                    let verified = try KVStore.verify(directory: restored)
                    return "备份序号 \(report.sequence)，恢复验证 \(verified.keys) 个 key。\n\(backup.lastPathComponent)"
                }}
                Text(summary).font(.caption).foregroundColor(.secondary)
                Text(message).textSelection(.enabled)
            }
        }.disabled(busy).navigationTitle("Strata Reader · gy") }
    }
    private func run(_ operation: @escaping (KVStore) async throws -> String) {
        busy = true
        let directory = directory
        Task {
            let result = await Task.detached { () -> Result<(String, Article?, StoreStatistics), Error> in
                do {
                    let store = try KVStore(directory: directory)
                    defer { store.close() }
                    let message = try await operation(store)
                    return .success((message, try store.namespace("articles").read(articleKey)?.value, try store.statistics()))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let (text, article, stats)):
                title = article?.title ?? "尚无离线文章"
                progress = article?.readProgress ?? 0
                message = text
                summary = "\(stats.keys) 个索引项 · \(stats.segments) 个日志文件 · \(stats.logBytes) B"
            case .failure(let error): message = "操作失败：\(error)"
            }
            busy = false
        }
    }
}
