# 验证范围

在 Windows 上编辑，通过 GitHub 的 macOS runner 使用 Apple SDK 验证。完整证据见 [CI](https://github.com/lllunimon-gy/strata-kv/actions/workflows/ci.yml)。

| 阶段 | 已确认结果 |
|---|---|
| v0.2，ae680dc | 18 项测试、6 个子进程中断场景、iOS Simulator 编译、Release 基准 |
| v0.3，95b4212 | 30 项测试、8 个子进程中断场景、iOS Simulator 编译 |
| v0.4 核心，1a035f8 | 44 项测试、原中断矩阵、iOS Simulator 编译、Release 基准 |
| v0.4 最终扩展，27f09dd | 46 项测试、12 个子进程场景、阅读示例 iOS Simulator 编译、SQLite 基准通过；15 项引擎测试在 Thread Sanitizer 下通过 |

核心测试覆盖：批次截断每个字节、完整头/正文损坏、严格恢复与证据备份、随机模型对照、CAS 竞争、TTL/迁移、分段序列、封存段损坏、压缩并发删除、快照引用、取消与关闭、合批背压与失败完成。

CI 只是当前构建与运行的证据。没有在每个支持的最低系统版本上运行，也没有执行 iOS 真机、磁盘耗尽、系统挂起、文件保护和断电实验。
Thread Sanitizer 不能证明没有所有可能的竞争；进程退出实验不能替代电源丢失。
性能数字均来自原始输出，保存于 Benchmarks/Results；方法与限制见 Benchmarks/README.md。

v0.4 代码验证：[CI 运行](https://github.com/lllunimon-gy/strata-kv/actions/runs/38915457127)。后续文档/原始结果归档不改变该次验证的源码。

## v0.4.1 性能复查

最终实现 `4ad47954d3d8c6b9fff8f7fcd822b7f7582cfa0d`：[CI](https://github.com/lllunimon-gy/strata-kv/actions/runs/38921488308)。52 项单元/边界测试、12 个进程中断场景、iOS Simulator 示例编译及 15 项引擎 Thread Sanitizer 测试通过。
库和 CLI 源码与第一轮已测候选 13d32d7 相同；读取拆分试验未采用，增加的时钟语义测试保留。
两轮完整同机交替测量、未改善项、保留/回退决定见 [性能回退复查](../Benchmarks/regression-analysis.md)。
常规 CI 保留标准基准；六轮历史版本对照通过手动 Run workflow 执行，避免文档改动重复触发昂贵实验。
