# Strata

[![CI](https://github.com/lllunimon-gy/strata-kv/actions/workflows/ci.yml/badge.svg)](https://github.com/lllunimon-gy/strata-kv/actions/workflows/ci.yml)

一个用于研究 iOS 本地持久化、崩溃恢复和磁盘回收的 KV 存储项目。作者 **gy**，MIT。
Swift 负责索引、事务边界和业务 API；Objective-C/C 负责文件锁、读写、同步和 CRC32。
支持 iOS 15+、macOS 12+，Swift tools 5.9，Swift 5 语言模式。

一次写入何时可以返回成功？压缩时又来了一个删除，重启后会不会把数据“复活”？
Strata 把这些问题放进可运行的实现和故障实验中。它适合学习和验证存储设计；真机低空间、文件保护、系统挂起和断电行为仍需另外测试。

## 已实现

| 范围 | 能力 | 对应入口 |
|---|---|---|
| 恢复 | 批次原子提交、头部/正文/提交尾 CRC、流式扫描、显式旧格式迁移 | `JournalCodec`、`Inspection` |
| 业务 | 命名空间、Codable 与 schema 迁移、TTL、CAS、快照分页 | `Operations`、`CodableStore`、`Snapshot` |
| 磁盘 | 日志分段、带校验的文件清单、后台压缩、孤儿文件清理 | `Manifest`、`Compaction` |
| 并发 | 单写者、多读者、自动合批、有界队列、压缩期间继续写入 | `KVStore`、`GroupedWriter` |
| 运维 | 只读检查、严格验证、备份后修复、备份与新目录恢复 | `strata-tool`、`Backup` |
| 实验 | 故障注入、子进程退出、线程竞争检查、Release 基准、SQLite 对照 | `Tests`、`Scripts`、`Benchmarks` |

## 在 Mac 上运行

```sh
swift test
swift build --product strata-tool
python3 Scripts/crash_matrix.py
swift run -c release strata-tool benchmark /tmp/strata-benchmark-new
```

基准目录必须不存在。Windows 可以阅读和修改代码；构建和实验依赖 Apple SDK，在 macOS CI 中运行。
用 Xcode 打开 `Examples/StrataExample.xcodeproj`，运行 **Strata Reader**：保存离线文章、记录进度、迁移旧模型、制造 CAS 冲突、观察草稿过期、合批写书签、压缩和备份恢复。
示例的文件操作离开主线程执行；每次操作结束关闭实例，方便反复验证重开行为。

## 从一个业务场景开始

```swift
let store = try KVStore(directory: url, recovery: .strict)
let reader = try store.namespace("reader")
try reader.put("position", value: Data("chapter-3".utf8))

let old = try reader.entry("position")
let result = try reader.compareExchange(
    "position", expectedRevision: old?.revision,
    value: Data("chapter-4".utf8)
)
// conflict 时重新读取并由业务决定，避免覆盖其他调用方的新位置。

let snapshot = try reader.snapshot()
let page = try snapshot.page(limit: 20)
// 翻页继续使用同一个 snapshot；游标不能用于另一个快照。

let report = try await store.compactInBackground()
store.close()
```

同步 API 应放在后台队列或应用自己的存储 actor 中。`GroupedWriter` 可以把多个已接纳请求合并为一个日志批次：

```swift
let writer = try GroupedWriter(store: store, maximumDelay: 0.002)
try await withThrowingTaskGroup(of: Void.self) { group in
    for n in 0..<100 {
        group.addTask { try await writer.writeBatch([.put("bookmark-\(n)", Data([1]))]) }
    }
    try await group.waitForAll()
}
try await writer.close() // 排空并同步；不会关闭 store
```

## 存储边界

- 每个目录只能有一个写实例；不支持 App 与 Extension 多进程共享写入。
- key 最多 1024 UTF-8 字节；值最多 8 MiB；一个批次最多 16 MiB 正文、4096 次操作。
- 默认每段目标 4 MiB。一整个批次不会拆开，单段可以超过目标大小；一个文件清单最多 8192 段，也会受到系统文件描述符限制。定期压缩。
- `.synchronized` 在日志同步后确认；`.fullSync` 对相关日志和清单执行 `F_FULLFSYNC`；`.buffered` 需要显式 `flush`，`close` 不自动保证落盘。目录单独 `fsync`。这些调用不能代替实际断电实验。
- 写入返回错误时可能已经提交。普通写入/文件清单发布失败后关闭重开，再读取确认；不要把错误理解为“肯定没写进去”。压缩在发布前取消则保留可用实例。
- 快照固定索引和 TTL 判定时间，保留文件描述符；长时间持有快照会延迟旧文件真正释放空间。
- 默认恢复策略只修剪经过验证的不完整活动段尾部。重要数据可选 `.strict`，先 `verify` 再显式 `repair`。完整帧损坏不会自动丢弃。
- v1 必须显式迁移。v0.4 会自动接管单文件 v2；升级后的目录不能交给旧版本写入，也不支持直接降级。无加密功能。

## 阅读顺序

1. [设计与并发边界](Documentation/design.md)：先掌握提交点、文件所有权和压缩发布。
2. [磁盘格式](Documentation/format.md)：对照十六进制文件理解校验顺序。
3. [业务 API](Documentation/business-api.md)：练习模型升级、过期和版本冲突。
4. [实验手册](Documentation/experiments.md)：复现中断、取消、快照保留和备份恢复。
5. [性能说明](Benchmarks/README.md)：看原始结果、同步次数和比较条件。
6. [验证范围](Documentation/validation.md) · [迭代记录](Documentation/roadmap.md) · [变更记录](CHANGELOG.md)。
