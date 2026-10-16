# Strata

一个能读懂磁盘格式、能在写入中途杀进程、能解释恢复结果的 KV 引擎。
作者 **gy** · MIT · iOS 15+ / macOS 12+ · Swift + Objective-C/C POSIX I/O。

## 运行

```sh
swift test
swift build --product strata-tool
python3 Scripts/crash_matrix.py
swift run -c release strata-tool benchmark /tmp/strata-benchmark-new
```

基准目录应使用新的专用目录。Xcode 打开 `Examples/StrataExample.xcodeproj` 可运行 iOS 示例。

```swift
let store = try KVStore(directory: directory, durability: .synchronized)
try store.writeBatch([.put("a", Data("one".utf8)), .put("b", Data("two".utf8))])
let value = try store.get("a")
try store.compact()
store.close()
```

## 已实现

追加日志、二进制批次格式、CRC32、提交标记、内存偏移索引、批量原子可见性、
启动恢复与尾部截断、删除标记、压缩替换、目录独占锁、同步/缓冲策略、进程退出故障矩阵、
格式查看工具与固定负载基准。读写被同一把锁串行化；值按偏移 pread，不常驻内存。

## 保证到哪里

同一目录只允许一个存储实例；不提供多进程共享读写、加密、TTL 或 MVCC。
每个批次最多 4096 个操作、16 MiB 编码内容；key 1–1024 UTF-8 字节，value 最多 8 MiB。
只有带合法提交标记与校验和的完整批次参与恢复。尾部不完整批次截断；完整帧损坏则报错并保留证据。
append/flush/compact 出错后必须关闭重开，禁止继续往可疑尾部追加。

同步模式调用 fsync 后才返回；它不等于所有设备上的抗断电承诺。
压缩先同步新文件再 rename；首版没有目录同步与 Apple F_FULLFSYNC 协议，
不承诺系统崩溃/断电期间目录项替换的耐久性。进程终止测试不覆盖这些情形。
缓冲模式由系统决定刷盘时机。close 不把缓冲模式升级为同步模式；需要时显式 flush。

启动会读取完整日志，内存峰值与日志长度相关；索引按 key 数增长。
这是可用于理解和实验的 v0.1，实现尚不适合未经评估承载不可丢失的生产数据。
mmap、分段日志与多读者并发属于后续练习，未写成已实现能力。

[磁盘格式](Documentation/format.md) · [恢复设计](Documentation/design.md) · [实验](Documentation/experiments.md) · [验证](Documentation/validation.md)
