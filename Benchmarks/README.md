# 性能实验

作者：gy。结果文件在 `Results/`，每份包含代码提交、CI 链接、操作系统、处理器数和原始统计。

```sh
swift run -c release strata-tool benchmark /tmp/strata-benchmark-new > benchmark.json
```

## 负载定义

| 名称 | 调用次数 × 批次 | 值大小 | 同步模式 |
|---|---|---|---|
| single-sync-write | 200 × 1 | 256 B | synchronized |
| batch-sync-write | 200 × 10 | 256 B | synchronized |
| random-read-warm-cache | 2000 次读取 | 256 B | OS 热缓存 |
| same-key-overwrite | 2000 × 1，反复覆盖同 key | 256 B | buffered，末尾 flush |
| reopen-warm-cache | 同目录重开 10 次 | 1 个活跃 key、2000 帧历史 | 热缓存 |
| compact-overwritten-log | 1 次压缩 | 上一项日志 | synchronized |
| sync-write-4096/65536-bytes | 各 200 × 1 | 4 KiB / 64 KiB | synchronized，含必要轮转 |
| automatic-group-sync-write | 200 轮，每轮 10 个独立请求 | 256 B | synchronized |
| SQLite 对照 | 分别 200 × 1、200 × 10 | 256 B | WAL + FULL，fullfsync=OFF |

自动合批计时从该轮第一个请求提交开始，到该轮全部回调结束，包含验证、排队和提交；P50/P95/P99 是每轮延迟。
基准参数是每组最多 10 个请求、最大等待窗口 10 ms，每轮立即提交满 10 条；尚未覆盖低流量下等待窗口对延迟的影响。库默认是最多 64 条、2 ms 窗口。
手动 batch 同样按整个批次计时。不要把“200 个批次”和“200 个 key”当成相同工作量。

SQLite 使用 Apple SDK 自带库、预编译 statement、WITHOUT ROWID 表，每批显式事务，关闭自动 WAL checkpoint。
Strata synchronized 对应 fsync 路径，SQLite 关闭 Apple fullfsync；二者的数据结构、缓存和元数据 IO 仍不同。
SQLite 字节数在连接关闭/最终 checkpoint 前统计，包含 db/WAL/SHM；Strata logBytes 只统计清单引用的日志，不含 manifest、备份、孤儿文件及被快照保留但已 unlink 的文件，不能直接当成全目录占用比较。
SQLite 不是 Strata 库的运行依赖，只有基准命令链接它。

## 如何解释数据

`syncCount` 是本实例发起的日志同步次数，包括头初始化、轮转、压缩和 flush，不统计 manifest 与目录同步；不能称为系统全部 fsync 次数。
`recoveryBufferBytes` 是恢复时最大单次读取，不是总内存。索引、临时解码、CoW 和快照仍有内存成本。
`processPeakResidentBytes` 是整个基准进程的峰值，包含所有前序负载及 SQLite，无法归因到某一个测试。
P99 用排序后的样本索引估算；200 次只适合发现明显变化，10 次 reopen 的高分位尤其不稳定。

v0.2 与 v0.4 使用不同次共享 CI 运行，不是受控同机 A/B。表中相同负载可观察量级，但不能仅凭一次下降声称固定百分比收益。
合批减少提交次数可由 frameCount/syncCount 验证；它也引入等待窗口。CRC 查表减少每字节位运算，不意味着整条写入链路同比加速。
压缩期间的并发正确性由确定性测试和线程检查器验证；真实业务下的读写尾延迟、空间峰值和能耗尚需真机负载记录。

当前不提供“比 SQLite 快”的统一结论。先检查负载是否与你的业务相似，再在同一设备、相同版本与相同持久性设置下重复实验。

[已记录的结果与对照表](results.md)。
