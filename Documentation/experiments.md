# 用失败点检查存储语义

## 写入中途结束进程

先运行 `swift build --product strata-tool`，再运行 `python3 Scripts/crash_matrix.py`。
脚本在独立临时目录写入两个旧值，然后在 header/payload/commit/sync 边界直接 _exit(86)。
预期：前两处重开都是 old，后两处都是 new，没有一个新一个旧。
压缩前后两个边界也会结束进程，值必须保持不变。

## 截断与损坏

testEveryTruncationOfSecondBatchIsAtomic 对第二个批次的每个字节位置做截断。
testChecksumCorruptionFailsWithoutModifyingEvidence 改写已提交 payload，重开必须报错且文件不变。
练习：扩展为随机位翻转，区分长度字段导致的“不完整尾部”与可验证的完整帧损坏。

## 一个可复现基准

Release 模式、全新目录、1000 个 256 字节值、每批 10 个操作、同步写入。
工具输出写入与读取时间。记录硬件、系统、提交 SHA，并多次运行报告中位数与尾部延迟。
与 SQLite 比较时，统一事务大小和同步条件；本仓库没有未经测量的性能领先声明。

## 下一轮实现题

1. 把启动恢复改为流式解析，保持所有损坏与截断测试通过，测量峰值内存。
2. 为 key 增加版本号并实现 compare-and-set，说明锁粒度和重试语义。
3. 引入只读 mmap 视图，先写映射生命周期与压缩切换测试，再测收益。
4. 将压缩拆成快照与增量合并，验证并发写入不会被旧快照覆盖。

每次只改变一个机制，保留旧实现作为实验对照。真机文件保护与掉电测试尚未执行。
