# 磁盘格式 v1

所有整数采用小端；读取按字节组合，不对任意地址作未对齐整数读取。
文件头为 8 字节 ASCII `STRATA01`。之后是连续批次：

| 字段 | 字节数 | 说明 |
|---|---:|---|
| magic | 4 | BCH1 |
| payloadLength | 4 | 最大 16 MiB |
| sequence | 8 | 从 1 连续递增 |
| CRC32 | 4 | sequence + operationCount + payload 的 IEEE CRC32 |
| operationCount | 4 | 1–4096 |
| payload | 可变 | 连续操作 |
| commit | 4 | CMIT |

操作格式：type 1 字节（1=put，2=delete），keyLength 4 字节，valueLength 4 字节，
UTF-8 key，原始 value。delete 的 valueLength 必须为 0；put 的空值与 delete 不同。
同一批次重复 key 按顺序覆盖。校验使用已知向量 123456789 → cbf43926。

解析先检查长度与上限，再访问数据，避免非法长度产生巨大分配。
批次全部验证完成后才更新索引。提交标记、CRC、序号、UTF-8、操作数量任一不合法都报错。
尾部不足一个完整帧时认定为未提交尾部；这无法区分短随机尾部与真实中断，协议明确接受该取舍。

压缩产生完整新文件，序号重新从 1 开始；sequence 不是跨压缩的业务版本号。
文件查看器的 inspect 会正常打开存储，因此可能执行尾部恢复；分析原始证据前先复制目录。
