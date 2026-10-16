# 参与 Strata

作者：gy。接口和说明使用中文讨论，代码标识符使用英文。

修改前先运行 `swift test`。修复问题时先写一个能复现问题的测试，避免只改示例。
提交前运行 `swift test --enable-code-coverage`，并构建 Examples 下的 iOS 工程。
测试应使用独立临时目录或 UserDefaults suite；不要访问使用者的真实缓存和偏好。

提交说明写清触发条件、修改后的行为和验证方式，例如
`fix: preserve the previous value when encoding fails`。
公共 API、磁盘格式或持久化承诺发生变化时，同时更新 Documentation 和 CHANGELOG。
基准数据必须记录设备、系统、构建模式和输入规模，保留原始输出。

不在 Issue 中粘贴真实用户路径、业务数据或授权凭据。
