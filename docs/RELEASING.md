# macOS 发布指南

macOS 与 [Windows](https://github.com/qx0657/allinai-quota-tray-windows) 独立构建、打标签和发布。本仓库正式产物为 `AllinAI-Quota.dmg`，更新检查只读取本仓库最新正式 GitHub Release。

## 版本与验证

同步修改 `build.sh` / `package_dmg.sh` 的 `APP_VERSION`、`APP_BUILD`，Swift `AppInfo.version` 的备用值，以及 README、CHANGELOG 和 AGENTS.md / CLAUDE.md 的版本。代理规则的共享区域应保持镜像。当前版本 0.2.0，构建号 2。

在 macOS、已安装 Swift 命令行工具的环境执行：

```sh
swiftc -typecheck Sources/AllinAIQuotaMenu.swift
swiftc -swift-version 6 -typecheck Sources/AllinAIQuotaMenu.swift
swiftc -target arm64-apple-macosx12.0 -typecheck Sources/AllinAIQuotaMenu.swift
zsh -n build.sh
zsh -n make_icon.sh
zsh -n package_dmg.sh
zsh -n Tests/run_tests.sh
./Tests/run_tests.sh
git diff --check
```

上面的目标架构对应官方 Apple Silicon 产物。构建脚本按本机架构生成单架构应用，部署目标和 `LSMinimumSystemVersion` 为 macOS 12.0；Intel 及最低系统版本尚未实机验收，不将 Apple Silicon DMG 标成通用版。

## 构建产物

```sh
./package_dmg.sh
hdiutil verify dist/AllinAI-Quota.dmg
hdiutil imageinfo dist/AllinAI-Quota.dmg
(cd dist && shasum -a 256 AllinAI-Quota.dmg > SHA256SUMS.txt)
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
```

打包会生成独立 bundle，不替换已安装应用，不修改账号、钥匙串或自启动。三个构建脚本共用图标暂存目录，不能并发执行。生成路径保持在忽略的 `dist/` / `.build/` 中。

挂载镜像后核对应用的版本、构建号、`LSUIElement=true`、`LSMinimumSystemVersion=12.0`，并用 `file` 和 `xcrun vtool -show-build` 核对 Mach-O 架构及最低系统版本；核对后卸载镜像。也可使用 `./build.sh --output "$PWD/.build/AllinAI Quota.app"` 检查独立 bundle，避免覆盖日常安装。

记录实测环境、测试数量、镜像校验与人工覆盖边界，参考[0.2.0 发布验证](verification/release-0.2.0.md)。自动测试不代表通知送达、VoiceOver 或最低系统实机验证。当前应用没有 Developer ID 签名或公证，下载后可能受到 Gatekeeper 拦截；发布说明应如实标注。

## 提交、标签与发布

先提交并推送全部源码与文档，在干净工作区构建上述产物。当前版本的示例：

```sh
git tag -a v0.2.0 -m "Release v0.2.0"
git push origin v0.2.0
```

标签必须对应构建所用提交；已发布标签不重写。将本版更新说明写到 `.build/release-notes.md`，包含支持架构、安装步骤与已知验证限制，然后上传草稿：

```sh
gh release create v0.2.0 --repo qx0657/allinai-quota-menu --verify-tag --draft \
  --title "v0.2.0" --notes-file .build/release-notes.md \
  dist/AllinAI-Quota.dmg dist/SHA256SUMS.txt
gh release view v0.2.0 --repo qx0657/allinai-quota-menu --json tagName,isDraft,isPrerelease,assets
```

核对资产名称、大小与 SHA-256 后发布：

```sh
gh release edit v0.2.0 --repo qx0657/allinai-quota-menu --draft=false --latest
gh api repos/qx0657/allinai-quota-menu/releases/latest
```

确认返回 `tag_name=v0.2.0`、非草稿、非预发布，并有 `AllinAI-Quota.dmg` 与 `SHA256SUMS.txt`。单独推送代码或 tag 不会让用户检查到新版。保留固定 DMG 名称，以便用户按客户端说明下载；Release 标题和标签区分版本。
