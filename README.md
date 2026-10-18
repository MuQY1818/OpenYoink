<div align="center">

<img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" alt="OpenYoink 图标">

# OpenYoink

**随手一拖，先放一下。**

免费的开源 macOS 暂存架与灵动岛。把文件放在手边，
也能在屏幕顶部控制音乐、专注计时、查看系统状态和找回剪贴板内容。

<br>

[![最新版本](docs/badges/release.svg)](https://github.com/MuQY1818/OpenYoink/releases/latest)
[![下载量](docs/badges/downloads.svg)](https://github.com/MuQY1818/OpenYoink/releases)
[![macOS 15+](docs/badges/macos.svg)](https://developer.apple.com/macos/)
[![GitHub Stars](docs/badges/stars.svg)](https://github.com/MuQY1818/OpenYoink/stargazers)
[![MIT 许可证](docs/badges/license.svg)](LICENSE)

[下载](https://github.com/MuQY1818/OpenYoink/releases/latest) ·
[官网](https://muqy1818.github.io/OpenYoink/) ·
[灵动岛](#灵动岛模块) ·
[演示短片](https://muqy1818.github.io/OpenYoink/#film) ·
[使用文档](https://muqy1818.github.io/OpenYoink/guide/) ·
[English](README.en.md)

</div>

<br>

<a href="https://muqy1818.github.io/OpenYoink/">
  <img src="docs/images/banner.jpg" width="100%" alt="OpenYoink — 随手一拖，先放一下">
</a>

把下载文件夹里的文件发到聊天窗口时，可以先拖进 OpenYoink，松开鼠标，再切到聊天窗口拖出去。

OpenYoink 常驻菜单栏，没有 Dock 图标。侧边暂存架和顶部灵动岛可以单独使用，也能一起开，两边的内容是共享的。

## 功能

- 暂存文件、文件夹、文本、图片和链接。来源应用支持时，也能接收邮件、日历事件和联系人。
- 按空格预览内容，支持多选、框选、堆叠（Stack）、搜索、类型筛选和撤销误删卡片。
- 通过边缘拉环、快捷键、鼠标摇动或拖拽唤出；可以按应用关闭自动唤出。
- 可选剪贴板历史，支持收藏、类型筛选、搜索、预览、复制和加入暂存架，默认不记录。
- 支持多显示器、多个 Space 和全屏应用，提供中英文界面、登录时启动和自动更新。

## 灵动岛模块

OpenYoink Island 把常用工具放到 Mac 顶部。收起时显示播放状态、倒计时或活动摘要，点击后展开对应模块。有刘海的 Mac 与物理刘海融合；外接屏和无刘海设备使用顶部悬浮胶囊。

### 模块预览

不用切回播放器，就能查看封面、歌曲信息和进度，暂停或切换歌曲；播放器支持时，也能拖动进度条。下面是 QQ 音乐的实际界面。其他播放器和浏览器视频的可用信息与控制能力取决于它们提供的媒体接口。

以下均为实际应用截图，点击可查看原图。

<table>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/now-playing.png"><img src="docs/screenshots/island/now-playing.png" width="100%" alt="OpenYoink 灵动岛正在播放模块，显示 QQ 音乐的封面、歌曲信息、进度和播放控制"></a>
      <p><strong>正在播放</strong><br>查看歌曲信息和封面，暂停、切歌；播放器支持时可拖动进度条。</p>
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/quick-access.png"><img src="docs/screenshots/island/quick-access.png" width="100%" alt="灵动岛快速访问，显示文件夹收藏、添加按钮和拖入添加区域"></a>
      <p><strong>快速访问</strong><br>收藏常用文件夹，双击用 macOS 默认文件管理器打开，兼容 Finder、QSpace 等。拖到收藏卡片上可复制文件，重名时询问。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/shelf.png"><img src="docs/screenshots/island/shelf.png" width="100%" alt="灵动岛暂存架，带有搜索、类型筛选和文件拖放区域"></a>
      <p><strong>暂存架</strong><br>与侧边架共享同一组内容，支持拖入、拖出、搜索、筛选和 Quick Look。</p>
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/clipboard-history.png"><img src="docs/screenshots/island/clipboard-history.png" width="100%" alt="灵动岛剪贴板历史，带有记录开关、搜索、类型筛选、收藏和复制操作"></a>
      <p><strong>剪贴板历史</strong><br>搜索复制过的文本、链接和图片，收藏常用内容，复制或加入暂存架。记录需单独开启。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/timer.png"><img src="docs/screenshots/island/timer.png" width="100%" alt="灵动岛计时器，显示专注、短休息、长休息、目标输入和时长选择"></a>
      <p><strong>专注计时</strong><br>选择专注、短休息或长休息，写下这一轮的目标；支持自定义时长、暂停、继续和专注记录。</p>
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/battery.png"><img src="docs/screenshots/island/battery.png" width="100%" alt="灵动岛电池模块，显示电量、电源状态、瓦数和最近两分钟的功率波形"></a>
      <p><strong>电池与功率</strong><br>查看电量、电源状态和充放电瓦数，动态波形保留最近两分钟，也显示平均功率。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/system-status.png"><img src="docs/screenshots/island/system-status.png" width="100%" alt="灵动岛系统状态，显示 CPU、内存、网络、磁盘、电池、热状态和应用占用排行"></a>
      <p><strong>系统状态</strong><br>查看 CPU、内存、网络速率、磁盘可用空间、电池、热状态和应用占用排行。只读，不结束进程或清理文件。</p>
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/island/module-library.png"><img src="docs/screenshots/island/module-library.png" width="100%" alt="灵动岛模块库，支持启停、打开、固定模块和拖动排序"></a>
      <p><strong>模块库</strong><br>按需启用功能，最多固定五个模块，拖动已固定的模块行调整顺序。未固定的模块仍可从库中打开。</p>
    </td>
  </tr>
</table>

电池功率反映电池侧的充放电，不是插座功耗。正值为充电，负值为放电；接通电源且电池充满时，接近 `0 W` 是正常情况。

传输模块还可以查看异步文件交付的进度和失败状态。

### 按自己的习惯配置

1. 在“设置 → 通用”开启 OpenYoink Island，新安装默认开启。
2. 展开后点击左上角齿轮进入模块库，启用需要的模块，点图钉固定到顶部。
3. 拖动已固定的模块行调整顺序；按 `Esc`、点击外部或顶部中央区域收起。

正在播放、快速访问和剪贴板历史模块默认关闭。开启剪贴板模块不会自动开始记录；侧边架与灵动岛可以独立开关。

顶部拖拽靠近展开默认关闭，可在“设置 → 触发器”单独开启，侧边暂存架的设置不受影响。

[灵动岛使用说明](https://muqy1818.github.io/OpenYoink/guide/island) · [模块详细说明](https://muqy1818.github.io/OpenYoink/guide/island-modules) · [观看 40 秒短片](https://muqy1818.github.io/OpenYoink/#film)

## 安装

需要 macOS 15 Sequoia 或更高版本，支持 Apple Silicon 和 Intel Mac。

### Homebrew（推荐）

```bash
brew install --cask muqy1818/tap/openyoink
```

Homebrew 从 GitHub Releases 下载安装包，并在安装后移除 OpenYoink 的隔离属性。这会跳过该应用的 Gatekeeper 隔离检查，但不等于 Apple 公证。

### 手动安装

1. 从 [GitHub Releases](https://github.com/MuQY1818/OpenYoink/releases/latest) 下载最新 DMG。
2. 打开 DMG，将 OpenYoink 拖入 `Applications`。
3. 首次启动若被 macOS 拦截，在 Finder 中右键 OpenYoink 并选择“打开”，或前往 **系统设置 → 隐私与安全性** 允许打开。

> [!NOTE]
> GitHub Releases 提供 ad-hoc 签名的社区构建，尚未经过 Apple 公证，手动安装可能被 macOS 拦截。自动更新使用 Sparkle EdDSA 校验，不能替代首次下载校验或 Apple 公证。

<details>
<summary>仍然无法打开？</summary>

先确认安装包来自上面的 GitHub Releases。运行 `shasum -a 256 OpenYoink-VERSION.dmg`（把 `VERSION` 换成实际版本号），与对应版本的 Release 校验值或 [Homebrew cask](https://github.com/MuQY1818/homebrew-tap/blob/main/Casks/openyoink.rb) 中的 `sha256` 比对。

确认来源和校验值后，可以用下面的命令移除 OpenYoink 的隔离属性。这会绕过该应用的 Gatekeeper 隔离检查：

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

</details>

## 快速上手

| 操作           | 方式                                                   |
| -------------- | ------------------------------------------------------ |
| 显示 / 隐藏    | `⌘⇧Space`、菜单栏菜单，或单击屏幕边缘的拉环           |
| 添加内容       | 拖到暂存架或边缘拉环上                                 |
| 托管移动       | 按住 `⌘` 拖入；确认副本后将原文件移入废纸篓，[详细说明](#文件安全与生命周期) |
| 暂存剪贴板     | 连按两次 `⌘⇧Space`                                     |
| 剪贴板历史     | `⌘⇧V`，可在设置中修改或关闭                           |
| 搜索 / 撤销移除 | `⌘F` / `⌘Z`（仅撤销手动移除的卡片）                  |
| Quick Look     | 选中卡片后按 `Space`，或双击卡片                       |
| 多选           | 按住 `⌘` 点选，或在空白处拖动框选                      |
| 移除           | 悬停后点 `×`、按 `Delete`，或右键菜单                  |
| 调整位置       | 沿屏幕边缘拖动拉环，或在设置中选择位置                 |
| 开启 / 关闭 Island | 设置 → 通用 → OpenYoink Island                    |

顶部拖拽展开默认关闭，可在设置中开启。侧边暂存架的拖拽唤出独立设置。更多操作见[使用文档](https://muqy1818.github.io/OpenYoink/guide/)。

## 文件安全与生命周期

普通拖入只保存原文件的引用，不移动原文件。移除卡片或开启“拖出后移除”也不会删除原文件。拖到 Finder 时只请求复制，最终是否接收由目标应用决定。

> [!WARNING]
> 按住 `⌘` 拖入会启用托管移动：先复制到应用沙箱，确认副本后，再把原文件移入废纸篓。失败时保留原文件并回退为普通引用。原文件只能在废纸篓尚未清空时恢复。

托管移动项目交付成功后，卡片和沙箱内副本才会删除，不受普通项目的“拖出后处理”设置影响。取消或交付失败会保留卡片和副本，供下次重试。

<details>
<summary>不同内容如何保存、何时清理</summary>

| 内容                       | OpenYoink 的处理方式                                   |
| -------------------------- | ------------------------------------------------------ |
| 文件与文件夹               | 保存原文件位置的访问授权（sandbox bookmark），默认不复制 |
| 纯文本与链接               | 直接记录在暂存架数据中                                 |
| 图片、HTML 与 RTF          | 保存为应用沙箱内的文件                                 |
| 联系人、日历事件与邮件     | 来源应用提供可读数据时，保存为 `.vcf`、`.ics`、`.eml`  |

若原文件被移动、删除或所在磁盘离线，卡片会显示不可用，直到文件引用重新解析成功。

文本和链接随卡片保存，移除时一并清除。图片、富文本、邮件等生成的文件在卡片移除后，通常在下次启动时清理；也可以在“设置 → 存储”查看和清理未使用文件。

普通文件拖出提供文件 URL 和 Chromium 兼容的文件名表示；托管移动使用 file promise，收到目标写入确认后才离架。兼容性仍取决于目标应用或网站。

</details>

## 隐私与权限

- 不需要账号，不收集分析数据或遥测。内容保存在本机沙箱内的 `Application Support/OpenYoink`。
- 应用启用 App Sandbox，只访问你主动拖入或选择的文件。正常使用不要求辅助功能或输入监控权限。
- 自动更新检查默认开启，可以关闭。应用的后台联网用于访问 GitHub Pages / Releases 检查和下载更新。
- 正在播放模块不联网，优先使用本地 helper，备用 Apple Music / Spotify AppleScript 可能请求“自动化”权限。模块失效不影响暂存架。
- 快速访问只保存你添加的文件夹引用。移除收藏不会删除真实文件夹，默认打开方式交给 macOS 决定。

### 剪贴板历史

记录默认关闭。没有开启时，只有连按两次快捷键暂存剪贴板才读取当前内容。开启或恢复后，只记录新复制的文本、HTTP(S) 网址和 PNG/TIFF 图片，不追溯旧内容，也不记录复制的文件。

历史在本机以明文保存，不上传、不同步。普通历史可选 30、100 或 300 条，默认 30 条；可保留 1、7 或 30 天，默认 7 天。另可收藏最多 30 项，不随天数过期；全部内容合计最多 20 MiB。关闭记录会保留已有历史，清空才会删除它们。

通用设置提供“文件暂存”“文件与剪贴板”“完整工具箱”预设，只调整模块和展开方式，剪贴板记录仍须单独开启。侧边暂存架和灵动岛的悬停、拖拽展开统一在“触发器”页设置。

会跳过常见密码管理器的隐私标记和忽略应用，但无法识别所有敏感内容。复制密码或令牌前，请先暂停记录。

## 从源码构建

开发环境需要 macOS 15+ 与 Xcode 26+。

```bash
git clone https://github.com/MuQY1818/OpenYoink.git
cd OpenYoink

xcodebuild \
  -project Open-Yoink.xcodeproj \
  -scheme OpenYoink \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Open-Yoink.xcodeproj \
  -scheme OpenYoink \
  -destination 'platform=macOS' \
  test \
  -only-testing:OpenYoinkTests
```

使用 Swift 6、SwiftUI 和 AppKit。本地构建无需设置 `DEVELOPMENT_TEAM`，上面的测试命令只运行应用单元测试，不运行 UI 自动化。

发布脚本见 [`Scripts/make-release.sh`](Scripts/make-release.sh)：支持 Developer ID 签名与公证，或显式传入 `--adhoc` 生成社区构建。签名失败不会自动降级。

## 参与项目

遇到问题或有功能建议，可以提 [Issue](https://github.com/MuQY1818/OpenYoink/issues)。报告问题时请附上 macOS 版本、OpenYoink 版本和复现步骤；截图中不要包含私人文件或剪贴板内容。

也欢迎 Pull Request。较大的改动先开 Issue 讨论，代码提交前请运行完整单元测试。

## Star History

<a href="https://www.star-history.com/?repos=MuQY1818%2FOpenYoink&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date&amp;theme=dark">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date">
    <img src="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date" width="800" alt="OpenYoink 在 GitHub 上的 Star 数量变化">
  </picture>
</a>

## 致谢与许可

OpenYoink 采用 [MIT License](LICENSE)。这是独立的开源项目，与商业应用 Yoink 及其开发者无隶属关系。

自动更新使用 [Sparkle](https://sparkle-project.org/)，Star 趋势图由 [Star History](https://www.star-history.com/) 提供。第三方组件与许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

<br>

<div align="center">

© 2026 weijue · MIT License

</div>
