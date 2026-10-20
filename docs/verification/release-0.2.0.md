# v0.2.0 发布验证

日期：2026-10-20。版本：0.2.0，构建号：2。环境：Apple Silicon / macOS 26.6.2 / Swift 6.0.3 / macOS SDK 15.2。

## 自动检查

- 默认与 Swift 6 严格模式类型检查通过。
- `arm64-apple-macosx12.0` 目标类型检查及优化编译通过。
- `build.sh`、`make_icon.sh`、`package_dmg.sh`、`Tests/run_tests.sh` 的 zsh 语法检查通过。
- `./Tests/run_tests.sh`：38/38 通过。原有 25 项覆盖额度、状态、认证、并发、限流、提醒与存储；新增 13 项覆盖版本比较、公开 GitHub 请求、每日调度、失败、冷却与取消。
- AGENTS.md / CLAUDE.md 标记区镜像检查通过。

测试使用模拟响应、临时目录与运行时生成的凭据，不请求真实账号数据。两仓的行为对应和测试场景见[原生同步约定](../NATIVE_PARITY.md)。

## 安装包检查

- `./package_dmg.sh` 成功，未替换 `/Applications` 中日常使用的应用。
- `hdiutil verify` 通过；`imageinfo` 为 UDZO 只读压缩镜像。
- 只读挂载并检查后已卸载：包含应用与 Applications 入口，bundle 版本 `0.2.0`、构建号 `2`、`LSUIElement=true`、`LSMinimumSystemVersion=12.0`。
- Mach-O 为 `arm64`，`LC_BUILD_VERSION` 的 `minos=12.0`、`sdk=15.2`，与 plist 一致。
- 正式发布时对最终 DMG 生成 `SHA256SUMS.txt`，与 DMG 一起上传；具体散列以该 Release 附件为准，不复用历史镜像的 CRC。

发布步骤见[发布指南](../RELEASING.md)。Release 标签指向的提交、附件和最终校验以 GitHub Release 为准。

## 覆盖边界

早期界面优化的用户实机确认和模拟预览保留在[原始记录](2026-10-20.md)，该记录的 0.1.0 版本、25 项测试和 CRC 仅对应当时产物。本轮未再次替换用户已安装应用或改变真实账号、自启动设置。

最低 macOS 12 和 Intel 尚未实机验收；本版仅发布 Apple Silicon DMG。通知实际送达、VoiceOver 及新增更新菜单的人工操作未逐项复测。应用没有 Developer ID 签名或公证；这些限制应随 Release 标明。
