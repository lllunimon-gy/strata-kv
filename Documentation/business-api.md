# 业务接口与一致性

作者：gy

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
当前实现复制清单及其引用的全部日志，期间持有写者锁，读取可继续；分段日志尚未把备份复制移到写者锁外。
restoreBackup 的源目录应是独立且不变的备份，不能一边被另一个实例写入一边恢复。

## 一个阅读进度的模型升级

```swift
struct Reading: Codable { let article: String; let offset: Int }
struct OldReading: Codable { let article: String; let position: Int }

let key = CodableKey<Reading>("reading", schemaVersion: 2, migrations: [
    1: { data in
        let old = try JSONDecoder().decode(OldReading.self, from: data)
        return try JSONEncoder().encode(Reading(article: old.article, offset: old.position))
    }
])
let account = try store.namespace("account-42")
let reading = try account.read(key)
// 读取到 v1 时，执行迁移并 CAS 写回；正常 v2 读取不重写磁盘。
```

迁移函数应只做数据转换。它可能因并发冲突被重复执行，不应发送网络请求或修改其他业务状态。
`set` 是普通覆盖写；需要拒绝旧业务版本时，使用 entry/compareExchange 自己表达冲突处理，不能把普通 set 当作条件更新。

## 跨命名空间的同一次提交

```swift
let articles = try store.namespace("articles")
let positions = try store.namespace("positions")
try store.writeBatch([
    try articles.putMutation("42", value: articleBytes),
    try positions.putMutation("42", value: Data("0".utf8))
])
```

Namespace.writeBatch 接受未编码的局部 key；已经通过 putMutation 编码过的 key 应交给 store.writeBatch，避免重复加前缀。
ttl 是相对保存时刻的秒数；批次接口的 expiresAt 是绝对 Date，方便同批操作共享准确到期时间。

## 分页生命周期

```swift
let snapshot = try articles.snapshot()
var cursor: PageCursor?
repeat {
    let page = try snapshot.page(prefix: "chapter-", after: cursor, limit: 50)
    for item in page.entries { print(item.key, item.revision) }
    cursor = page.next
} while cursor != nil
```

PageCursor 虽可 Codable，但它绑定进程内的这份快照，不能持久化后重建一个新快照继续使用。
快照作用域结束即释放引用；不要为了一个长列表永久保存所有旧快照。

## 错误如何交还业务

| 结果 | 处理方式 |
|---|---|
| CAS conflict | 读取当前 revision，由业务合并或提示冲突 |
| queueFull | 根据业务合并、延后或拒绝新操作，不能假装成功 |
| futureSchema / missingMigration | 保留原数据，补齐兼容逻辑 |
| invalidCursor | 重新创建快照，从第一页开始 |
| compactionInProgress | 保持当前任务，不重复发起 |
| requiresReopen / 写入 IO 错误 | 关闭重开并检查实际值，再决定是否重试 |
| corruption / invalidManifest | 停止自动写入，保留文件与备份用于诊断 |

StoreStatistics.keys/liveValueBytes 统计索引里未物理清除的项，可能包含已到期值；业务可见 key 应从 keys()/snapshot 读取。
