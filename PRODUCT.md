# AllinAI Quota Menu

<!-- impeccable:product-schema 1 -->

## Platform

macOS，原生菜单栏工具。Windows 在独立仓库中使用 C# / WinForms 维护。

## Users

用户于 2026-10-20 确认：个人单账号使用，主要查看额度、余额和到期提醒；没有有效订阅时，也有使用账户余额消费的场景。

## Product Purpose

在不中断当前工作的情况下，快速了解 AllinAI 的订阅额度或账户余额，以及数据更新时间与订阅有效期。

## Operating Context

- 常驻 macOS 菜单栏，菜单栏空间有限。
- 当前实现为 Swift、AppKit、Foundation、Security，使用 shell 脚本构建与打包。
- 当前开发版本为 0.2.0；发布通过 GitHub Releases。

## Capabilities and Constraints

- 保持菜单栏应用形态与 `LSUIElement`，保留中文交互。
- 保持轻量；按实际需要调整模块，不引入大型依赖或包管理器。
- 密码通过 macOS Keychain 保存；令牌仅为本地运行数据。
- `config.json` 仅保存邮箱与刷新间隔；新增显示偏好可另用 UserDefaults。
- 自启动继续使用当前用户的 LaunchAgent，保留名称“开机自启动”。
- 菜单底部保留“版本：v<version>”。
- 真实服务地址继续使用 `https://allincode.top/api/v1` 与 `https://allincode.top/subscriptions`。
- 余额与订阅额度分别表达，不把二者直接相加。

## Evidence on Hand

- `Sources/AllinAIQuotaMenu.swift`、README、构建与打包脚本。
- 用户提供的菜单截图：主要信息偏灰、订阅已过期、账户仍有余额。
- `research/` 中保存的历史网页脚本；它们是历史参考，不代表已核实的现行服务契约。
- 用户确认的单账号与余额消费场景。

## Open Decisions

- 有效订阅额度耗尽后，服务是否自动改扣余额，尚未确认。
- 零值／缺失限额、额度重置窗口的正式服务契约，尚未确认。

## Confirmed Decisions

- 用户已同意按优化方案实施：原生只读信息区、订阅／余额自适应图标、可选数值，以及默认关闭的可选提醒。
- 用户于 2026-10-20 确认：检查更新默认仅手动触发，可主动开启每日自动检查；通过“关于”访问更新、发布记录与开源地址。
- 用户于 2026-10-20 决定继续分别维护原生仓库，不合仓或引入跨平台运行库。两端通过[行为对应与同步检查](docs/NATIVE_PARITY.md)维护业务一致性；此前跨平台方案仅为未采用的选型记录。
