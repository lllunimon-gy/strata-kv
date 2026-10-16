# Strata

面向 iOS 小数据持久化的 KV 存储实验。作者 **gy**，MIT，Swift + Objective-C/C。
支持 iOS 15+ / macOS 12+，Swift 5.9+。先阅读存储语义，再接入业务。

## 运行

```sh
swift test
swift build --product strata-tool
python3 Scripts/crash_matrix.py
swift run -c release strata-tool benchmark /tmp/strata-benchmark-new
```

Xcode 打开 `Examples/StrataExample.xcodeproj`。基准使用新的专用目录，输出 JSON，包括 P50/P95/P99、刷盘计数和进程峰值 RSS。

## v0.2

- 带独立头部校验的日志格式，长度字段损坏不会被当作未完成尾部。
- 流式恢复，每次只读取一个有界批次；有效 key 索引仍占用 O(key 数) 内存。
- 批量提交、删除、CRC32、同步/缓冲/F_FULLFSYNC 模式、压缩与目录同步。
- 只读 inspect/verify，显式 repair，v1 → v2 迁移与原始备份。
- 运行时不常驻历史帧摘要，诊断时按需扫描。

```swift
let store = try KVStore(directory: url, recovery: .strict)
try store.writeBatch([.put("reader", Data("gy".utf8)), .put("theme", Data("dark".utf8))])
let value = try store.get("reader")
try store.compact()
store.close()
```

默认 recoverIncompleteTail 会修剪已确认不完整的 v2 尾部；重要数据可选择 strict，先运行只读 verify，再决定是否显式 repair。
repair 会保存备份，拒绝完整帧损坏。旧 v1 文件必须执行 `strata-tool migrate <目录>`，不会在普通打开时默默升级。

## 使用限制

每个目录一个实例；方法同步执行，应离开主线程。key 最大 1024 字节，单值 8 MiB，单批次 16 MiB/4096 个操作。
发生写入或切换文件错误后，实例需要关闭重开；错误不一定表示操作未提交。
缓冲模式 close 不保证刷盘，需要显式 flush。fsync、F_FULLFSYNC 与目录同步的结果会检查，但不承诺所有硬件条件下的抗断电能力。
本库无加密。真机文件保护、后台挂起、低空间与能耗实验仍需单独验证。

[格式](Documentation/format.md) · [实验](Documentation/experiments.md) · [迭代记录](Documentation/roadmap.md)
