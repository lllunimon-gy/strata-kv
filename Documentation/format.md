# 磁盘格式 v2

全部整数采用小端。文件头 24 字节：STRATA02（8）、baseSequence（8）、前 16 字节的 CRC32（4）、保留零（4）。

批次头 28 字节：BCH2（4）、payloadLength（4）、sequence（8）、operationCount（4）、bodyCRC（4）、前 24 字节的 headerCRC（4）。
先校验固定头，再解释长度。payload 最大 16 MiB，操作数最多 4096。

操作：type（1）、keyLength（4）、valueLength（4）、revision（8）、expiration 的 Double 位模式（8）、UTF-8 key、value。
type=1 普通 put，129 带到期时间的 put，2 delete。无到期时间时位模式必须为 0。
revision 在压缩后保持，sequence 是日志提交高水位，二者不混用。

提交尾 16 字节：CMT2（4）、sequence（8）、前 12 字节 CRC32（4）。
全部校验通过后才应用一个批次。完整头损坏必须报错；验证过的头对应内容缺失，才可按策略视为未完成尾部。
极短尾部仍无法在所有情况下区分随机损坏与未完成写入；strict 模式拒绝它，recoverIncompleteTail 模式接受截断。

v1 只提供严格读取与显式迁移。原文件会备份，新文件写入并校验、同步后原子替换，再同步目录。
无法验证的 v1 尾部不会自动修复。每次迁移使用独立临时文件和备份，不覆盖上一份证据。
