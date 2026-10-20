---
name: AllinAI Quota Menu
description: 原生 macOS 菜单栏额度与余额界面的现行设计记录。
colors:
  warning-light: "color(srgb 0.62 0.15 0.11 / 1)"
  warning-dark: "color(srgb 1 0.62 0.58 / 1)"
  caution-light: "color(srgb 0.52 0.33 0.04 / 1)"
  caution-dark: "color(srgb 1 0.72 0.36 / 1)"
typography:
  brand:
    fontFamily: NSFont.systemFont
    fontSize: 13pt
  title:
    fontFamily: NSFont.systemFont
    fontSize: 13pt
  amount:
    fontFamily: NSFont.systemFont
    fontSize: 28pt
  amount-long:
    fontFamily: NSFont.systemFont
    fontSize: 22pt
  percentage:
    fontFamily: NSFont.monospacedDigitSystemFont
    fontSize: 21pt
  detail:
    fontFamily: NSFont.systemFont
    fontSize: 11.5pt
  label:
    fontFamily: NSFont.systemFont
    fontSize: 11pt
  body:
    fontFamily: NSFont.systemFont
    fontSize: 12pt
  status-number:
    fontFamily: NSFont.monospacedDigitSystemFont
    fontSize: 12pt
rounded:
  quota-progress: 2.5pt
spacing:
  summary-inset: 18pt
  summary-top: 12pt
  summary-bottom: 9pt
  section-gap: 7pt
  detail-gap: 3pt
components:
  account-summary:
    width: 352pt
  quota-progress:
    height: 5pt
    rounded: "{rounded.quota-progress}"
  status-icon:
    size: 18pt
---

# Design System: AllinAI Quota Menu

## Overview

**Creative North Star: "数据可信度优先于装饰"**

保留轻量、安静的原生 macOS 菜单栏界面。核心金额最先可见，消费模式与数据时效紧随其后；系统菜单承担操作，自定义只读信息区承担阅读。订阅额度与账户余额分别表达，风险通过文字与符号说明。

本记录提取自现行 `Sources/AllinAIQuotaMenu.swift` 的 `SummaryView`、`QuotaProgressView`、`ProgressIcon`、`AppearanceStyle` 与原生菜单实现，沿用已批准的优化方案。尺寸使用 AppKit 逻辑点（pt）；系统字体与语义颜色保留原生 API 含义。sidecar 的组件为原生 AppKit 记录，组件预览字段留空。

证据范围：已查看 `.build/previews/` 中订阅、余额、额度耗尽、离线、未知与未登录六组亮暗 AppKit 状态样例；样例使用模拟数据。25 项模拟测试与 Swift 6 typecheck 已通过，独立 reviewer 对四项界面修复给出 ship。用户提供的实际深色余额菜单、账号工具子菜单及数值模式截图已核对，未见文字溢出或布局错位；用户完成本轮核心菜单检查后确认功能无问题。VoiceOver、其他系统外观设置、通知送达及菜单快捷键未逐项实测，这些记录不代表完整实机交互或可访问性认证。

**Key Characteristics:**

- 原生 NSMenu 操作与自定义只读概览并用。
- 核心金额优先，账号、周期、时效与解释分层呈现。
- 文字、符号与可访问名称共同说明状态，颜色仅作辅助。

## Colors

系统语义色为基础，少量动态警示色只用于状态。顶部 token 只记录源码中明确的自定义 sRGB 亮暗端点，不采样或替换系统颜色，也不生成未使用的色阶。

### Primary

`NSColor.controlAccentColor` 用于剩余比例高于 30% 的额度条，跟随用户的系统强调色。

### Neutral

`NSColor.labelColor` 用于标题与正常核心金额；`NSColor.secondaryLabelColor` 用于账号、辅助说明、状态文字与更新时间；`NSColor.quaternaryLabelColor` 用于额度条轨道。背景与菜单材质交给 `NSMenu`，概览本身不绘制背景。

### State

`AppearanceStyle.warningText` 根据 `.aqua`／`.darkAqua` 选择 `warning-light`／`warning-dark`，用于剩余不高于 10% 或暂无可用额度的核心提示，以及登录表单错误。`AppearanceStyle.caution` 同样选择对应亮暗端点，用于剩余高于 10%、不高于 30% 的额度条。状态不只依赖颜色；额度耗尽、离线、未知与登录失效均有文字或符号。

**The Native Color Rule.** 系统语义色由 AppKit 随外观与系统设置解析；不要把预览采样色固化为主题色。

## Typography

全部文字使用系统字体 API；顶部 token 记录实际字号，不指定固定字体文件。字重保留 `NSFont.Weight` 语义：品牌与主金额为 `.semibold`，标题、百分比与可选菜单栏数值为 `.medium`，说明与标签为 `.regular`。

| Token | 用途 |
| --- | --- |
| `brand` / `title` | AllinAI 标识与当前订阅／消费模式 |
| `amount` / `amount-long` | 主金额与状态；文字超过 12 个字符时使用较小字号 |
| `percentage` | 主金额右侧、右对齐的剩余百分比，采用等宽数字 |
| `detail` / `label` | 周期、用量、到期、时效说明，以及账号、标题旁状态与 caption |
| `body` | 登录表单的说明与错误文字 |
| `status-number` | 用户主动开启的菜单栏金额／百分比，采用等宽数字 |

概览普通单行标签按字号的 1.45 倍向上取整计算容器高度；这不是统一行高。多行说明按原生文本测量计算高度。

**The Readable Data Rule.** 只读概览继续使用正常文字层级；核心金额不能借用禁用态来表达不可编辑。

## Layout

`SummaryView` 采用顶部 token 所列的默认宽度与左右内边距，垂直依次呈现品牌／账号、订阅或消费模式、可选状态提示、指标名称、金额／百分比、可选额度条、解释与时效。视图高度随实际内容计算；当前实现没有用户可调整字号或自动增宽逻辑。

账号右对齐并在中间截断；订阅标题在尾部截断，标签保留完整可访问名称。状态提示与解释行可换行。长订阅说明移入详情，超过摘要长度时由“完整说明…”打开原生可滚动文本。

菜单将刷新、订阅入口与详情放在前面，刷新间隔、自启动、账号与工具集中在后面，底部保留版本与退出。系统菜单项尺寸、焦点、选中态和分隔线由 AppKit 管理；菜单打开时只更新概览与刷新可用性。

## Elevation & Depth

自定义概览不增加阴影、边框或额外材质层。层级来自字级、正常／辅助文字色、留白与系统菜单分组。菜单窗口的材质、圆角与阴影由 macOS 决定；静态状态预览的底色不构成应用背景 token。

## Shapes

额度条采用顶部 token 指定的细圆角轨道。菜单栏图标采用统一模板画布；订阅圆环在其中绘制直径 14pt 的环，轨道线宽 1.8pt、剩余弧线宽 2.3pt，弧线端点为圆头，中心保留直径 2pt 的点。系统菜单、按钮与输入框沿用原生形状。

## Components

### 只读账户概览 — `SummaryView`

放入 `NSMenuItem.view`，由正常文本标签组成。订阅模式突出剩余金额与百分比，余额模式突出账户金额。离线与刷新失败保留最近成功数据并给出状态提示；未知值使用明确文案或 `--`。账号、百分比与标签均设置可访问名称，实际 VoiceOver 阅读顺序仍待验证。

### 剩余额度条 — `QuotaProgressView`

仅订阅模式使用，长度表达剩余比例；零剩余只显示轨道。使用 `.progressIndicator` 辅助功能角色，标签为“剩余额度”，值为格式化百分比。颜色遵循 Colors 的阈值。

### 菜单栏状态 — `ProgressIcon` 与 `NSStatusItem`

默认紧凑方形状态项；全部图像设为 `isTemplate = true`，由系统呈色。订阅用剩余圆环，余额用 `dollarsign.circle`，无可用额度用 `exclamationmark.circle`，未知用 `questionmark.circle`，账号状态用 `person.crop.circle`。

“菜单栏显示数值”默认关闭；开启后使用可变宽度。余额模式显示金额并隐藏图像，其余模式显示图像与数值／状态。旧数据在数值前加 `~`，tooltip 与可访问名称提供完整状态。正常刷新保留当前信息，不增加持续动画。

### 原生操作与登录表单

操作沿用 `NSMenu` 的勾选项、子菜单、快捷键与启用状态，保留“开机自启动”和“版本：v<version>”。登录使用临时 `NSPanel`、`NSTextField`、`NSSecureTextField` 与 `.rounded` 按钮；Return 提交、Esc 取消，错误在表单内显示。控件外观由 AppKit 决定。

## Do's and Don'ts

### Do:

- Do 保留系统语义文字色、系统菜单材质与原生控件行为。
- Do 让概览高度随内容计算，长说明换行，截断标题仍提供可读取的完整名称。
- Do 统一用“剩余”描述圆环、百分比和额度条，余额单独显示金额。
- Do 保留最近成功数据，并明确离线、部分失败与成功更新时间。
- Do 在修改后核对亮暗状态样例，并单独验证真实菜单交互与辅助功能。

### Don't:

- Don't 把核心金额或状态做成 disabled 菜单项。
- Don't 固化系统动态颜色，或为菜单额外增加自定义阴影、玻璃层与装饰背景。
- Don't 为余额绘制没有真实分母的进度，也不把未知数据表示成零。
- Don't 把亮暗静态预览、模拟测试或 typecheck 当作真实菜单与 VoiceOver 已验收。
