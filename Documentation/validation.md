# 验证范围

在 Windows 上编辑，通过 GitHub 的 macOS runner 使用 Apple SDK 验证。完整证据见 [CI](https://github.com/lllunimon-gy/strata-kv/actions/workflows/ci.yml)。

| 阶段 | 已确认结果 |
|---|---|
| v0.2，ae680dc | 18 项测试、6 个子进程中断场景、iOS Simulator 编译、Release 基准 |
| v0.3，95b4212 | 30 项测试、8 个子进程中断场景、iOS Simulator 编译 |
| v0.4 核心，1a035f8 | 44 项测试、原中断矩阵、iOS Simulator 编译、Release 基准 |
| v0.4 最终扩展 | 正在验证：46 项测试、12 个子进程场景、阅读示例、SQLite 基准、Thread Sanitizer |

核心测试覆盖：批次截断每个字节、完整头/正文损坏、严格恢复与证据备份、随机模型对照、CAS 竞争、TTL/迁移、分段序列、封存段损坏、压缩并发删除、快照引用、取消与关闭、合批背压与失败完成。

CI 只是当前构建与运行的证据。没有在每个支持的最低系统版本上运行，也没有执行 iOS 真机、磁盘耗尽、系统挂起、文件保护和断电实验。
Thread Sanitizer 不能证明没有所有可能的竞争；进程退出实验不能替代电源丢失。
性能数字均来自原始输出，保存于 Benchmarks/Results；方法与限制见 Benchmarks/README.md。
