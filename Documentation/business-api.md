# 业务接口与一致性

## Namespace

`let reader = try store.namespace("reader")`。命名空间使用长度前缀编码，冒号和 Unicode 名称不会因简单拼接而碰撞。
这是逻辑隔离，不是权限边界；原始 KV 接口仍能访问编码后的 key。1024 字节上限包含命名空间前缀。
跨命名空间原子修改：构造各自的 putMutation/deleteMutation，再交给同一次 store.writeBatch。

## TTL

`try reader.put("draft", value: data, ttl: 60)` 保存绝对过期时间。读取到期值返回 nil，purgeExpired 写删除标记，压缩才回收空间。
时间来自可注入时钟；同一实例内夹紧回拨时间，重启后仍依赖系统墙钟。因此不能用于防篡改的安全过期策略。
快照按创建时刻冻结可见性；快照里的值不会因时间经过突然消失。

## Codable/schema

CodableKey 指定 schemaVersion 和逐版本迁移。编码、迁移在存储锁外执行；迁移最终使用 CAS 提交。
迁移期间业务写入新版本，迁移会重读，最多重试三次。解码失败保留原始字节；未知未来版本不会被默认值覆盖。
迁移保留原过期时间，不延长 TTL。

## CAS

entry 返回 value、revision、expiresAt。compareExchange 仅在当前可见 revision 匹配时提交。
expectedRevision=nil 表示当前不存在或已经到期，不表示这个 key 从未存在。
revision 与日志物理位置分离，压缩和恢复不重置它。批量内的值共享本次提交 revision。

## 稳定分页

先持有 snapshot，再调用 page(prefix:after:limit:)。游标属于这一个快照和查询前缀，不能跨快照复用。
快照固定数据版本和时间，持有旧文件句柄，因此数据库继续写入、压缩或 close 后仍可读取。
按 key 排序，分页使用二分定位；快照创建需要 O(key 数) 的索引与排序空间。

## 备份与恢复

backup 在一致性边界复制数据，校验和同步后才发布目标目录。目标必须不存在。
restoreBackup 只恢复到新目录，拒绝覆盖已有数据库。备份保留 revision 与绝对到期时间。
首版备份期间阻塞写入；后续分段日志可减少这段停顿。
