# 原生版本同步维护

2026-10-20：决定分别维护 macOS / Windows 原生仓库。这个小工具继续保持各平台实现；不合仓，不引入跨平台 UI 或共享运行库。

Windows 仓库：[allinai-quota-tray-windows](https://github.com/qx0657/allinai-quota-tray-windows)，[对应维护说明](https://github.com/qx0657/allinai-quota-tray-windows/blob/main/docs/NATIVE_PARITY.md)。本轮 Windows 0.2.0 功能同步基于 macOS `79e417d`，Windows 实现完成于 `8c759ba`；这些是行为基线提交，不是后续发布提交。

## 功能对应

macOS 类型均位于 `Sources/AllinAIQuotaMenu.swift`。

| 行为 | macOS 实现 | Windows 实现 |
| --- | --- | --- |
| 有效订阅、最受限周期、余额和未知状态 | `QuotaPolicy` | `Core/Models.cs` 的 `QuotaPolicy` |
| 独立资源快照和成功时间 | `AccountSnapshot` | `Core/Models.cs` 的 `AccountSnapshot` |
| 验证后保存、认证恢复、并发续期 | `AllinClient` actor | `Core/Client.cs` 的 `AllinClient` |
| 刷新、取消、冷却、退避与睡眠 | `QuotaStore` | `Core/QuotaStore.cs` |
| 提醒阈值、初次静默与去重 | `ReminderManager` | `Core/QuotaStore.cs` 的 `ReminderManager` |
| 独立 GitHub 更新与每日检查 | `ReleaseClient` / `UpdateChecker` | `Core/Updates.cs` |
| 只读信息区与登录 | `SummaryContent` / `SummaryView` / `LoginPanelController` | `SummaryContent` / `SummaryPanel` / `LoginForm` |

## 一致的业务约定

- 每日剩余 80%、每周剩余 10% 时展示每周；缺失用量不能补零，缺失限额不能当作无限额度。
- 过期订阅保留在详情中，不能遮住余额；有效订阅耗尽不能自行改为余额消费。
- 一项接口失败不清空另一项的成功数据；非认证错误不反复密码登录。401 仅重试被拒绝的资源，并发续期合并，退出后迟到响应不能恢复会话。
- 服务限流冷却覆盖手动、定时、唤醒与网络恢复；睡眠暂停，恢复时合并请求。
- 提醒默认关闭，初次观察静默，按账号、订阅和周期去重。
- 更新默认手动；可选自动检查最多每日一次，失败计入频率，GitHub 冷却跨重启保留，更新不携带账户凭据。

## 保留的平台差异

- macOS：AppKit / Keychain / 当前用户 LaunchAgent；Windows：WinForms / Credential Manager / 当前用户 HKCU Run。
- macOS 支持图标旁数值和系统模板图标。Windows 以黑白轮廓图标适配任务栏，数值放在 tooltip 与概览中，托盘溢出由系统和用户设置决定。
- macOS 使用系统通知权限与投递 API；Windows 使用托盘通知并排队，系统决定实际是否展示。
- 两端分别读取各自仓库的 GitHub Releases，分别构建和发布；不要求构建号或发布日期强制绑定。

## 修改时怎么同步

1. 改业务规则前写清相同输入的预期结果，对照上表检查另一仓库是否受影响。
2. 各自修改生产实现，并在 Swift `Tests/AllinAIQuotaTests.swift` / C# `Tests/CoreTests.cs` 添加必要的同类行为用例。
3. 在提交说明中记录是否需要对应平台修改；已同步时引用对方提交，平台差异说明原因。
4. 分别执行原生构建验证。模拟 UI、交叉编译与业务测试不能代替两端真实菜单、通知或高 DPI 验收。

服务对缺失限额、重置窗口及订阅耗尽后扣费的正式契约尚未确认。客户端继续表达未知，不以两端一致为理由自行决定后端规则。此前[跨平台重写方案](design/cross-platform-proposal-2026-10-20.md)仅保留为未采用的历史选型记录。
