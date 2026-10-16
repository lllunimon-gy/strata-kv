# 磁盘格式 v2 与 checkpoint

全部整数采用小端，CRC 为 IEEE CRC32。单值最大 8 MiB、key 最大 1024 UTF-8 字节；正文最大 16 MiB、每批最多 4096 次操作。

## 文件头：24 字节

| 偏移 | 字节数 | 字段 |
|---|---|---|
| 0 | 8 | `STRATA02` |
| 8 | 8 | baseSequence |
| 16 | 4 | 文件头 CRC |
| 20 | 4 | flags：0 普通段，1 checkpoint |

普通段延续早期 v2：CRC 覆盖前 16 字节，flags 必须为 0。checkpoint 的 CRC 覆盖“前 16 字节 + flags”，flags 必须为 1。
改变 flags 也会使校验失败。其余 flag 值拒绝读取。
普通段从 baseSequence+1 开始连续提交；checkpoint 内所有帧的 sequence 都等于 baseSequence，表示同一份已提交状态的不同块。
checkpoint 只能是文件清单的第一段，后面必须有普通活动段。空数据库允许 baseSequence=0 的空 checkpoint，但不允许 sequence=0 的数据帧。

## 批次

头部 28 字节：`BCH2`（4）、payloadLength（4）、sequence（8）、operationCount（4）、bodyCRC（4）、headerCRC（4）。headerCRC 覆盖前 24 字节。
读取顺序必须先验证 headerCRC，再使用 payloadLength；否则损坏的长度可能被误判成可修剪尾部。

正文每个操作：type（1）、keyLength（4）、valueLength（4）、revision（8）、expiration 的 Double 位模式（8）、UTF-8 key、value。
type=1 普通 put；129 带到期时间的 put；2 delete。无到期时间时位模式为 0；delete 的 valueLength 必须为 0。
revision 大于 0 且不超过该帧 sequence。压缩保留 revision，CAS 比较它，不比较文件偏移。

尾部 16 字节：`CMT2`（4）、sequence（8）、前 12 字节 CRC（4）。完整正文和尾部全部校验通过后才应用批次。
同批次重复 key 按操作顺序应用。

## 文件清单

`manifest.json` 是 `{payload: base64(JSON), crc: UInt32}`。payload 包含 `generation` 和有序 `files`。
限制为 1 MiB、最多 8192 个不重复文件名。名称只允许 `store.log` 或 `segment-<UUID>.log`。
下一普通段的 baseSequence 必须等于前一段的最终 sequence。删除标记跨段合并，不能只合并每段剩余的 put。
目录内其他日志不参与恢复。若发现分段文件却缺少清单，会拒绝打开，不能退回旧 store.log 或创建空数据库。
`vacuumOrphans()` 只删除未被引用且名称符合规范的日志、manifest 临时文件；保留备份、未知文件和符号链接。
旧 checkpoint 名称虽以 segment 开头，格式类型由文件头判定。

## 尾部与迁移

完整头或完整帧损坏必须报错。经过校验的头对应内容缺失，才可视为未完成尾部。极短尾部仍无法区分所有随机损坏与未完成写入；strict 拒绝，recoverIncompleteTail 可修剪活动段。
显式 repair 先复制活动段作为证据、同步备份，再修剪；不修复封存段损坏。

v1 仅严格读取和显式迁移：保存原文件备份 → 写临时 v2 → 验证与同步 → 替换并同步目录。
无法验证的 v1 尾部不会自动修复。无清单的完整单文件 v2 打开时接管为清单管理。
v0.4 目录不能由不识别清单/checkpoint 的旧版本继续写入，降级应从升级前独立备份恢复到另一个目录。
