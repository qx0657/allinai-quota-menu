# AllinAI Quota Menu

轻量原生 macOS 菜单栏工具，用于查看 AllinAI 订阅额度、账户余额和到期状态。常驻菜单栏，打开即可判断当前还能使用多少额度。

**当前版本：0.2.0 · 构建号：2 · 平台：macOS**

适合个人单账号使用。基于 Swift 与 AppKit，保持单文件源码，不依赖第三方运行库或包管理器。

Windows 版本：[qx0657/allinai-quota-tray-windows](https://github.com/qx0657/allinai-quota-tray-windows)。

## 功能概览

- **订阅与余额自适应**：有有效订阅时展示剩余额度；无有效订阅且余额充足时进入余额消费模式。
- **菜单栏状态图标**：订阅使用剩余圆环，余额使用货币图标；支持切换为剩余百分比或余额数值。
- **清晰的账户概览**：展示额度周期、已用／剩余金额、到期时间、余额与更新时间，订阅详情保留历史记录。
- **可控的刷新**：默认 5 分钟，可选 1／5／10／30 分钟；支持手动刷新、睡眠暂停、唤醒与网络恢复后刷新。
- **可选提醒**：到期、低额度和低余额提醒默认关闭，用户主动开启后申请系统通知权限。
- **保留最近数据**：网络或部分接口失败时保留成功获取的数值，明确标记旧数据和失败原因。
- **本地凭据管理**：密码保存在 macOS 钥匙串，令牌保存在当前用户的本地目录；支持重新登录与退出登录。
- **原生使用体验**：中文菜单、可选开机自启动、亮暗外观适配；运行时不显示 Dock 图标。
- **GitHub 检查更新**：“关于”中提供手动检查、可选每日自动检查、更新记录与开源地址。

## 界面预览

以下为生产 AppKit 信息区使用**模拟数据**渲染的预览，不含原生操作菜单。实际菜单功能已由用户实机确认，详见[验证记录](docs/verification/2026-10-20.md)。

| 订阅模式 · 浅色 | 余额模式 · 深色 |
| --- | --- |
| ![订阅模式概览](docs/verification/images/subscription-light.png) | ![余额模式概览](docs/verification/images/balance-dark.png) |

菜单栏图标与数值的亮暗状态样例：

![浅色菜单栏状态样例](docs/verification/images/icons-light.png)

![深色菜单栏状态样例](docs/verification/images/icons-dark.png)

## 快速开始

### 从源码构建安装

需要 macOS 与可用的 Swift 命令行工具，构建时使用 `swiftc`、`sips`、`iconutil` 和 `plutil`；打包另需 `hdiutil`。应用需要连接 `https://allincode.top`。

如果旧版正在运行，先从菜单选择 **退出**，然后在仓库根目录执行：

```sh
./build.sh
open "/Applications/AllinAI Quota.app"
```

默认安装位置：`/Applications/AllinAI Quota.app`。构建脚本会重新生成应用图标，在临时目录完成编译与 bundle 校验后替换目标；编译失败保留旧应用，替换失败会尝试恢复旧应用。

构建独立副本：

```sh
./build.sh --output "$PWD/.build/AllinAI Quota.app"
open "$PWD/.build/AllinAI Quota.app"
```

`--output` 必须是以 `.app` 结尾的绝对路径。应用按 bundle identifier 防止重复运行，测试独立副本前也应退出已有实例。

当前已在 Apple Silicon、Swift 6.0.3 环境完成构建与测试。脚本默认按本机架构编译，不生成通用二进制；最低 macOS 版本和 Intel Mac 尚未单独验收。当前构建脚本不执行 Developer ID 签名或公证。

### 使用已有 DMG

打开 `AllinAI-Quota.dmg`，将 **AllinAI Quota.app** 拖入镜像内的 **Applications** 入口，再从“应用程序”启动。更新时先退出旧进程，再替换并重新打开应用。

### 首次登录

1. 点击菜单栏中的 AllinAI 图标，选择 **登录…**。
2. 输入 AllinAI 邮箱与密码，提交后等待登录结果；错误会直接显示在登录面板中。
3. 登录成功后自动刷新账户，按订阅与余额状态显示对应概览。

已有本地会话时，启动后会尝试恢复并刷新。正常使用时无需手动编辑配置文件。

## 显示规则

| 账户状态 | 信息区与菜单栏显示 |
| --- | --- |
| 有有效订阅且额度完整 | 突出最受限周期的剩余金额、剩余百分比与进度；圆环表达剩余比例 |
| 无有效订阅，余额大于零 | 显示“余额消费”和账户余额；默认使用货币图标 |
| 无有效订阅，余额不大于零 | 显示“暂无可用额度”与警示图标 |
| 订阅或额度信息不完整 | 显示待确认说明、问号或 `--`；缺失数据不会当作零或无限额度 |
| 刷新失败且已有成功数据 | 保留最近数据和成功更新时间；主指标依赖的数据刷新失败时，菜单栏数值前加 `~` |
| 未登录或登录失效 | 显示账号图标与登录提示 |

**剩余比例的口径一致**：圆环、进度条和百分比都表示“剩余”，不是“已用”。每日、每周、每月额度同时存在时，优先展示剩余比例最低的已知周期。例如每日剩余 80%、每周剩余 10% 时，主指标为每周剩余 10%。其他已知周期仍在概览中展示。

订阅额度与账户余额分别显示，不直接相加。有效订阅额度耗尽时，仍明确显示该订阅已耗尽；服务是否会自动改扣余额尚未确认，应用不据此自动切换消费模式。

有多个有效订阅时，可通过 **订阅详情 → 对应订阅 → 在菜单栏显示此订阅** 切换主指标。此选择仅保留在当前运行期间。过期订阅仍可在详情中查看，不占用余额模式的主要信息区。

## 菜单与设置

| 菜单入口 | 用途 |
| --- | --- |
| 立即刷新 | 更新订阅与账户信息；请求执行中、登录失效或限流冷却期间不可用 |
| 打开订阅页 | 在浏览器打开 AllinAI 订阅页面 |
| 订阅详情 | 查看已有订阅的状态、周期用量、起止时间与说明；长说明可展开阅读 |
| 刷新间隔 | 选择 1／5／10／30 分钟，默认 5 分钟 |
| 开机自启动 | 通过当前用户的 LaunchAgent 在登录时启动，无需管理员权限 |
| 账号与工具 → 重新登录… | 打开登录面板，验证成功后保存新的登录信息 |
| 账号与工具 → 退出登录… | 确认后清除本地令牌及对应钥匙串密码，保留邮箱、刷新间隔和其他偏好 |
| 账号与工具 → 菜单栏显示数值 | 默认关闭；订阅模式显示剩余百分比，余额模式直接显示金额并隐藏重复货币图标 |
| 账号与工具 → 提醒设置 | 管理通知总开关与低余额阈值 |
| 账号与工具 → 打开配置文件夹 | 在 Finder 中打开本地数据目录 |
| 关于 AllinAI Quota → 检查更新… | 检查 GitHub 最新正式版；发现新版后可打开对应 Release 下载页面 |
| 关于 AllinAI Quota → 自动检查更新（每天） | 默认关闭；开启后最多每 24 小时检查一次，发现新版时在菜单中提示 |
| 关于 AllinAI Quota → 更新记录… | 打开本仓库的 GitHub Releases |
| 关于 AllinAI Quota → 开源地址（GitHub）… | 打开本项目源代码仓库 |
| 退出 | 结束应用进程，保留本地登录信息 |

### 检查更新

通过 **关于 AllinAI Quota → 检查更新…** 查询[本项目最新正式版](https://github.com/qx0657/allinai-quota-menu/releases/latest)。请求执行期间显示“正在检查更新…”，避免重复请求；成功后显示上次检查时间。

- 更新源为 GitHub REST API 的 `GET /repos/qx0657/allinai-quota-menu/releases/latest`，公开仓库无需 GitHub 令牌。
- 按 `主版本.次版本.修订号` 数值比较版本，标签可带 `v` 前缀；忽略草稿与预发布，不会提示安装较旧版本。正式版发布请使用 `v0.2.0` 这样的标签。
- 手动检查会明确提示有新版、当前无需更新、暂无正式版或检查失败；限流后遵守 GitHub 的重试时间，重启也不会绕过冷却。
- **自动检查默认关闭**。开启后启动、唤醒或运行中会检查是否已满 24 小时；时间间隔跨重启保留，失败也计入每日请求频率。后台检查不弹窗、不申请通知权限；发现新版后，“关于”显示“有新版本”，子菜单提供“下载 vX.Y.Z…”入口，菜单栏悬停说明也会提示。
- 更新使用浏览器打开对应 Release，查看说明并下载 `AllinAI-Quota.dmg`，退出旧应用后拖入“应用程序”替换并重新启动。

更新请求与 AllinAI 账号完全独立，不发送邮箱、密码或登录令牌。仅在手动检查或已开启自动检查时连接 GitHub；网络无法访问 GitHub 时，账户额度查询仍可独立运行。

### 菜单快捷键

以下是原生菜单项快捷键，不是系统全局热键；未登录或操作不可用时，对应菜单项可能不显示或不可用。

| 操作 | 快捷键 |
| --- | --- |
| 立即刷新 | `⌘ R` |
| 打开订阅页 | `⌘ O` |
| 登录／重新登录 | `⌘ ,` |
| 退出登录 | `⌘ L` |
| 退出应用 | `⌘ Q` |
| 关闭展开的菜单 | `Esc` |

### 提醒设置

在 **账号与工具 → 提醒设置** 中开启 **开启额度与到期提醒**，并允许 macOS 通知。提醒默认关闭。

| 提醒类型 | 触发条件 |
| --- | --- |
| 订阅到期 | 有效订阅进入到期前 3 天、1 天阈值 |
| 订阅低额度 | 已知主周期的剩余额度不高于 10% |
| 低余额 | 在余额模式或余额不足状态下，余额不高于所选阈值 |

低余额阈值可选 **关闭／$1／$5／$10**，默认关闭。仅选择阈值不会开启通知总开关。

提醒在应用运行且相关数据成功刷新后检查，实际提示时间受刷新间隔、网络和系统通知设置影响。启动时已有的告警条件会静默记录，不补发历史提醒；同一账号、订阅和周期内的相同阈值会去重。

### 刷新与异常恢复

- 订阅与余额分别保留最后一次成功结果和更新时间，一项失败不会覆盖另一项的成功数据。
- 认证错误才会尝试会话恢复；离线、限流或服务器错误不会触发反复密码登录。
- 同时发生的令牌续期会合并；一次刷新只重试被认证错误拒绝的资源。
- 请求失败后使用有上限的退避；服务返回限流冷却时间时，自动刷新、手动刷新和唤醒刷新都会遵守。
- 系统睡眠时暂停刷新；唤醒或网络恢复后合并刷新请求，减少重复请求。

## 本地数据与隐私

| 数据 | 位置与内容 |
| --- | --- |
| 应用数据目录 | `~/Library/Application Support/AllinAIQuotaMenu/` |
| `config.json` | 仅保存邮箱 `email` 与刷新间隔 `refreshIntervalSeconds` |
| `tokens.json` | 当前账号的 access／refresh token 等本地会话信息 |
| 密码 | macOS 钥匙串，service：`local.allinai.quota.menu` |
| 显示、提醒与更新偏好 | UserDefaults 域：`local.allinai.quota.menu`，同时保存提醒去重、显式退出状态、检查更新时间与限流冷却 |
| 自启动配置 | `~/Library/LaunchAgents/local.allinai.quota.menu.plist` |

数据目录权限为 `0700`，配置与令牌文件权限为 `0600`。令牌是本机敏感运行数据，不应加入版本库或公开反馈；密码不写入配置文件或令牌文件。

订阅与余额快照仅保存在当前进程内存中，不持久化用量历史。应用退出后，下次启动需要重新获取这些数值。

支持旧版 `AllinCodeQuotaMenu` 数据迁移：新目录不存在时迁移旧目录；读取到旧版明文密码配置时，将密码转存至钥匙串并重写为仅含邮箱、刷新间隔的配置。迁移可能需要钥匙串授权。

## 开发与验证

### 项目结构

```text
.
├── Sources/AllinAIQuotaMenu.swift      # 模型、请求、状态、原生界面与入口
├── Tests/
│   ├── AllinAIQuotaTests.swift        # 隔离的功能与回归测试
│   └── run_tests.sh                   # 测试及原生预览入口
├── Assets/
│   ├── logo.png                      # 应用图标源图
│   └── AllinAIQuota.icns              # 生成的应用图标
├── build.sh                          # 构建与安装，可指定输出位置
├── make_icon.sh                      # 生成 icns；菜单栏图标在 Swift 中绘制
├── package_dmg.sh                    # 生成 DMG 安装包
├── docs/
│   ├── design/                       # 优化方案与设计样例
│   ├── verification/                 # 验证记录与模拟数据预览
│   └── images/                       # 旧版历史截图
├── PRODUCT.md                        # 产品目标与使用约束
├── DESIGN.md                         # 已实现的设计规范
├── AGENTS.md                         # 仓库协作规则
├── research/                         # 历史网页／接口参考材料
└── dist/                             # 本地打包输出
```

源码保持单文件，按职责分段：

| 模块 | 职责 |
| --- | --- |
| 模型、`QuotaPolicy`、`Format` | 接口类型、消费模式、额度选择与格式化 |
| `LocalStorage`、`Keychain` | 配置、令牌、凭据与旧版数据迁移 |
| `AllinClient` actor | 登录、令牌续期、接口请求与错误分类 |
| `QuotaStore`（MainActor） | 账户快照、刷新调度、取消与会话代次 |
| `ReminderManager` | 阈值检查、提醒去重与通知投递 |
| `ReleaseVersion`、`ReleaseClient`、`UpdateChecker` | 正式版比较、独立 GitHub 请求、每日更新检查与限流冷却 |
| `SummaryContent`、`SummaryView`、`QuotaProgressView`、`ProgressIcon` | 展示内容与原生视图；渲染时不读文件或钥匙串 |
| `AppDelegate`、`LoginPanelController`、`StartupManager` | 菜单、登录面板与系统集成 |

### 类型、脚本与回归检查

修改 Swift 或构建脚本后，在 macOS 仓库根目录运行：

```sh
swiftc -typecheck Sources/AllinAIQuotaMenu.swift
swiftc -swift-version 6 -typecheck Sources/AllinAIQuotaMenu.swift
zsh -n build.sh
zsh -n make_icon.sh
zsh -n package_dmg.sh
zsh -n Tests/run_tests.sh
./Tests/run_tests.sh
```

测试使用隔离的 URLProtocol、临时目录、生成的测试凭据和内存凭据存储，不请求真实服务、不读取真实钥匙串。覆盖消费模式、周期额度、部分失败、认证恢复、并发续期、退出后的迟到响应、限流、提醒、颜色对比度、文件权限，以及更新版本比较、每日调度、取消与失败处理。

生成亮暗原生信息区与菜单栏状态样例：

```sh
./Tests/run_tests.sh --render-previews "$PWD/.build/previews"
```

预览使用模拟数据，不能代替真实菜单、通知或 VoiceOver 验证。2026-10-20 的本轮验证已通过 25 项测试、构建与镜像检查，核心菜单功能获得用户实机确认；完整证据与覆盖边界见[验证记录](docs/verification/2026-10-20.md)。

## 打包与版本管理

### 生成 DMG

```sh
./package_dmg.sh
hdiutil imageinfo dist/AllinAI-Quota.dmg
hdiutil verify dist/AllinAI-Quota.dmg
```

输出为 `dist/AllinAI-Quota.dmg`。打包脚本调用同一构建入口生成独立 bundle，不替换 `/Applications` 中的已安装应用；核对版本后生成临时镜像，成功后才替换已有 DMG，并清理暂存目录。

图标生成会共用暂存目录，`build.sh`、`make_icon.sh` 与 `package_dmg.sh` 应依次执行。

### 更新版本

以下两个脚本中的版本与构建号必须同步：

- `build.sh`
- `package_dmg.sh`

当前值：

```sh
APP_VERSION="0.2.0"
APP_BUILD="2"
```

同时更新 `Sources/AllinAIQuotaMenu.swift` 中 `AppInfo.version` 的备用值和本 README。应用正常运行时从 bundle 的 `CFBundleShortVersionString` 读取版本，并在菜单底部显示 `版本：v<version>`。

### 发布供应用检查的新版

1. 同步升级上述版本信息，运行类型检查和回归测试。
2. 执行 `./package_dmg.sh`，验证生成的 `dist/AllinAI-Quota.dmg`。
3. 在[本仓库 Releases](https://github.com/qx0657/allinai-quota-menu/releases) 创建与应用版本一致的标签，例如 `v0.2.0`，填写更新说明并上传 `AllinAI-Quota.dmg`。
4. 发布为正式 Release，设为最新版本；草稿、预发布和单独创建的 Git tag 不会成为此更新接口的正式更新。

无需另建更新服务器或在客户端配置 GitHub 令牌。新版本只有发布到 GitHub Release 后，其他用户才会检查到。

安装后可核对元数据：

```sh
plutil -extract CFBundleShortVersionString raw "/Applications/AllinAI Quota.app/Contents/Info.plist"
plutil -extract CFBundleVersion raw "/Applications/AllinAI Quota.app/Contents/Info.plist"
plutil -extract LSUIElement raw "/Applications/AllinAI Quota.app/Contents/Info.plist"
```

`.build/`、`Assets/*.iconset/`、`dist/*.dmg`、`dist/dmg-stage/` 为忽略的生成路径。本地账号配置、令牌与钥匙串数据不得提交。

## 服务接口

应用使用真实服务地址；`AllinAI` 是应用名称，服务域名继续保留 `allincode.top`。

- API 根地址：`https://allincode.top/api/v1`
- 订阅页面：[AllinAI 订阅页](https://allincode.top/subscriptions)

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/auth/login` | 登录 |
| POST | `/auth/refresh` | 续期令牌 |
| GET | `/subscriptions?timezone=<local-timezone>` | 获取订阅及周期额度 |
| GET | `/user/profile` | 获取账户信息与余额 |

接口响应使用 `{ code, message, data }` 包装。`research/` 中的历史参考不代表现行服务契约；缺失限额、周期重置窗口及订阅耗尽后的扣费规则仍需以后端正式约定为准。

## 常见问题

**没有 Dock 图标，是不是没有启动？**

这是菜单栏应用，bundle 保留 `LSUIElement`。请在 macOS 菜单栏查找 AllinAI 状态图标或余额数值。

**更新后为什么仍像旧版本？**

替换 bundle 不会自动重启已有进程。先从旧应用菜单选择“退出”，再重新打开已安装应用。

**菜单栏的 `~` 或 `--` 表示什么？**

`~` 表示当前主指标来自最近一次成功获取的数据，本次刷新未能确认；`--` 表示数据或状态不足以判断。可查看菜单中的失败原因和成功更新时间。

**为什么“立即刷新”暂时不可用？**

请求处理中、需要重新登录或服务限流冷却期间会暂停该操作。登录问题通过“重新登录…”处理，其余情况按菜单提示等待或检查网络。

**开启提醒后为什么没有马上弹窗？**

提醒需要应用运行、系统通知授权和成功刷新；还需检查提醒总开关与低余额阈值。启动时已存在的条件静默记录，相同条件不会反复通知。

**移动应用后自启动怎么办？**

LaunchAgent 记录可执行文件路径。在新位置启动应用后，重新开启“开机自启动”，将配置更新为当前路径。

## 相关文档

- [产品目标与约束](PRODUCT.md)
- [优化设计方案](docs/design/optimization-proposal-2026-10-20.md)
- [已实现的设计规范](DESIGN.md)
- [实施与验证记录](docs/verification/2026-10-20.md)
