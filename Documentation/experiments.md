# 实验手册

作者：gy。所有破坏性实验使用临时目录，先保存原文件，再修改字节。

## 1. 先预测，再运行崩溃矩阵

```sh
swift build --product strata-tool
python3 Scripts/crash_matrix.py
```

| 中断位置 | 重开期望 |
|---|---|
| 写完批次头、写完正文 | 未提交，保留旧值；活动段尾可修剪 |
| 写完提交尾、同步后 | 完整批次可恢复；调用方可能没收到成功 |
| 压缩发布前、发布后 | 两个版本都恢复相同逻辑内容 |
| 分段清单发布前、发布后 | 原已提交值完整，未写的新批次不存在 |
| 压缩期间先更新 a、删除 b、新增 c，再中断发布 | a/c 为新值，b 不复活 |
| v1 迁移发布前、发布后 | 重试迁移后值正确，原备份完整 |

共 12 个子进程场景，使用 `_exit(86)`，不跑析构和正常关闭。
这验证进程异常退出；没有模拟电源突然断开、设备缓存丢失或目录项回滚。

## 2. 损坏长度字段

运行 `StoreTests.testCorruptLengthWithinLimitNeverTruncatesEvidence`。
它把完整帧长度改为另一个仍在上限内的值：旧逻辑很容易以“内容不够长”为由截断，当前格式先发现头 CRC 错误，拒绝写入和 repair，原字节必须不变。
再看 `testEveryTruncationOfSecondBatchIsAtomic`：遍历第二个批次的每个截断位置，结果只能是完整第一批。

```sh
swift run strata-tool inspect /path/to/database
swift run strata-tool verify /path/to/database
swift run strata-tool repair /path/to/database
```

前两条只读；repair 取得目录锁，保存备份后才能修剪。对重要目录先离线操作。

## 3. 读是否被慢写堵住

`EngineTests.testReadersSeeCommittedDataWhileWriterIsPaused` 在写完批次头时阻塞写者。
另一个线程必须在释放写者之前读到旧值，随后写者完成，新读取看到新值。
若把 pread 和 fsync 都放回同一把锁内，这个测试会超时。

```sh
swift test --scratch-path .build/tsan --sanitize=thread --filter EngineTests
```

线程检查器覆盖引擎并发测试；它只报告本次运行经过的路径，不证明所有调度都无竞争。

## 4. 压缩和快照

先保存 update/delete/keep，创建快照。压缩捕获完成后更新 update、删除 delete、再制造多次分段。
发布并重开：新实例必须看到新状态；旧快照仍读到捕获值，即使 store 已 close。
观察旧路径已删除但空间可能未立即回收——快照持有描述符。释放最后一份快照后再观察磁盘，区分逻辑日志大小与真实占用。

取消实验在 captured 阶段阻塞，取消任务后释放。应抛 CancellationError；实例仍能写新值并重开。
关闭实验在 captured 阶段 close；后台任务退出前另一个实例不能抢到租约，原任务不能在关闭后发布。

## 5. TTL、迁移和 CAS

示例保存 10 秒草稿，分别在到期前后读取。未执行 purge/compact 时，文件大小不会因为 get 返回 nil 自动缩小。
单实例内时钟回拨会钳制；跨重启仍使用墙钟，因此不要把 TTL 当成防篡改计时器。
阅读 `BusinessTests` 中的迁移竞争：迁移函数执行期间注入一笔新写，旧迁移必须 CAS 失败后重读，不能覆盖新值或延长 TTL。

## 6. 备份与容量限制

示例会创建独立备份，再恢复到新目录验证；它会保留这些目录，重复实验后可在应用容器中清理。
测试尝试覆盖已有目录，必须拒绝。故意损坏备份后恢复，目标不能发布为可用数据库。
合批测试将待处理请求上限设为 1：第二笔应收到 queueFull；close 必须排空第一笔，所有等待者都结束。

## 7. 性能记录

```sh
swift run -c release strata-tool benchmark /tmp/strata-bench-new > benchmark.json
```

保存提交、运行环境、配置和原始 JSON。比较相同次数、值大小和批次大小。每次换新目录；重复至少 5 次，再讨论波动和尾延迟。
[性能说明](../Benchmarks/README.md) 解释各负载和 SQLite 对照条件。

真机补充：锁屏后的文件保护、后台任务超时、低磁盘空间、热状态、能耗和频繁 fsync 的成本。当前仓库未把这些实验标记为已完成。
