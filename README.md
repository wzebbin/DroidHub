# DroidHub

原生 macOS 工具，通过 USB 或 Wi‑Fi 管理 Android 手机。支持文件传输、照片和视频、应用管理、设备信息、投屏、截图和录屏。

![DroidHub 浅色模式下的文件管理主界面，显示演示文件和传输队列](assets/screenshots/file-manager.png)

## 下载与安装

**[下载 DroidHub 0.3.115 开发预览版](https://github.com/wzebbin/DroidHub/releases/tag/v0.3.115)** · Apple 芯片 Mac（arm64）

安装包内置 ADB 和 scrcpy，手机无需安装配套应用。最低构建目标为 macOS 13，该版本的实机兼容性尚待验证。 [验证记录](docs/VALIDATION.md)

1. 从 Release 页下载 `DroidHub-0.3.115-macOS-arm64.zip` 和同名 `.zip.sha256`，放在同一目录。在该目录运行 `shasum -a 256 -c DroidHub-0.3.115-macOS-arm64.zip.sha256` 校验。
2. 解压 ZIP，将 `DroidHub.app` 拖入「应用程序」。
3. 首次打开时，macOS 可能会拦截未经 Apple 公证的预览包。确认下载来源和校验结果后，如果「系统设置 → 隐私与安全性」提供「仍要打开」，可从那里打开。

也可以[从源码构建](#从源码构建)。

## 首次连接

- **USB**：用支持数据传输的线连接手机，解锁并在「开发者选项」开启 USB 调试。手机出现「允许 USB 调试」时点「允许」。若未出现弹窗，重新插拔数据线并看一下手机屏幕。
- **Wi‑Fi**：手机和 Mac 连同一 Wi‑Fi。在手机「开发者选项 → 无线调试」（Android 11+）开启开关，在 DroidHub 选择「连接设备 → 配对新设备」。可用手机扫码，也可在手机打开「使用配对码配对」，保持弹窗打开，填写其中的地址和六位数字。
- **已配对但找不到**：用「输入连接地址」填写手机无线调试主页当前显示的 IP 和端口。重新开启无线调试后请读取新端口。若 Mac 拒绝过局域网访问，可在「系统设置 → 隐私与安全性 → 本地网络」允许 DroidHub 后重试。

<img src="assets/screenshots/wifi-pairing.png" alt="DroidHub 的 Wi-Fi 配对表单，显示示例地址占位符和空白配对码输入框" width="544">

## 主要功能

- 「设备」查看电量、存储和系统信息。点「开始投屏」打开独立窗口。连接手机后也可直接截图或录屏，录屏支持实时计时，停止后保存为 MP4。当前投屏和录屏只处理画面。
- 「全部文件」支持 Finder 拖入、文件和文件夹双向传输、批量移动和重命名、回收站和恢复。
- 「照片」支持日期分组、相册、搜索、照片预览、视频播放和导出原文件。
- 「应用管理」支持按应用名称或包名搜索，查看版本、大小，安装、启动、卸载和导出安装包。拆分应用导出为包含各 APK 的 ZIP，应用数据不包含在内。
- 在「设置」选择浅色、深色或跟随系统，即时切换简体中文和 English，并可设置关闭主窗口时直接退出、隐藏窗口或每次询问。

## 目录

```text
macOS/       Swift Package，可用 Xcode 打开 Package.swift
  Sources/DroidHub/       原生桌面界面、操作状态
  Sources/DroidHubCore/   ADB、子进程、照片扫描和导出
  Helpers/               随 Mac 应用打包、通过 ADB 调用的 Android 文件操作和应用元数据工具
  Tests/                 设备解析、特殊文件名、shell 引用测试
scripts/     Mac 构建与测试脚本
docs/        发布版本验证记录
dist/        本地构建产物（不提交）
```

## 从源码构建

0.3.115 在 Apple 芯片 Mac 上使用 Xcode 27.2（Swift 6.4.2）验证。打包还需要 Android NDK 28.2.13676358、Android SDK Platform 34、Build Tools 36.0.0 和 JDK 17 或更新版本。Android SDK 默认位于 `~/Library/Android/sdk`，可用 `ANDROID_SDK_ROOT` 指定其他位置。可用 `ANDROID_NDK_HOME` 指定 NDK 目录，用 `JAVA_HOME` 指定 JDK 目录。

可以克隆仓库，也可以在 GitHub 仓库页面下载源码 ZIP 并解压。首次打包需要联网获取 ADB 和 scrcpy。

```bash
git clone https://github.com/wzebbin/DroidHub.git
cd DroidHub
```

在项目根目录运行以下命令。

```bash
./scripts/test-macos.sh
./scripts/build-macos.sh
open dist/DroidHub.app
```

日常开发可用 Xcode 打开 `macOS/Package.swift` 并运行 DroidHub target。完整功能验收请启动脚本生成的 `dist/DroidHub.app`，其中包含 ADB、scrcpy 和 Android 辅助工具。

构建脚本按目标架构从官方来源获取并校验固定版本的 ADB 和 scrcpy，缓存至 `.build/bundled-tools`，并打包到 `DroidHub.app`。应用默认使用内置工具，可用的自定义路径会优先使用。打开 **DroidHub → Settings（⌘,）** 可查看当前状态，在「高级设置」可修改路径或恢复内置路径。

## 手动发布与更新

1. 在 Apple 芯片 Mac 上运行 `./scripts/test-macos.sh` 和 `./scripts/build-macos.sh --release`。验收 `dist/` 下的 ZIP 和 SHA‑256。
2. 根据第三方声明核对随包组件和对应分发材料。预发布草稿使用与构建对应的标签（如 `v0.3.115`），附上安装包、校验文件、项目许可证和适用的第三方材料。scrcpy 源码附件包含对应源码、重链脚本和使用说明，和安装包放在同一 Release。 [第三方声明](licenses/README.md) · [GitHub Releases](https://github.com/wzebbin/DroidHub/releases)
3. 预览版可在 Releases 页面手动下载。应用内「检查更新」查询 GitHub 的最新正式 Release。升级时先完成或暂停传输，退出 DroidHub，再替换应用。

## 反馈

报告问题时，请注明 DroidHub 版本、macOS 版本、手机型号、Android 版本、USB 或 Wi‑Fi 连接方式，以及复现步骤。连接问题可以附上「连接设备 → 复制诊断信息」的输出。 [GitHub Issues](https://github.com/wzebbin/DroidHub/issues)

## 许可

DroidHub 源码采用 MIT 许可证。随包第三方组件按各自的许可证分发。 [项目许可证](LICENSE) · [第三方声明](licenses/README.md)

## 当前限制

- 此版本面向 Mac，不包含 Windows 工程。
- 照片扫描 ADB 可读的 `DCIM` 和 `Pictures`，视频另外扫描 `Movies`。其他可访问路径可从「全部文件」打开。
- 图库使用 LazyVGrid 按需显示图片。大批量首次读取原图的速度受 ADB 连接和文件大小影响。
- 传输队列保存在 Mac。退出或断开后，重新连接原手机并点击「重试未完成任务」。上传和下载文件夹时跳过校验一致的文件，64 MiB 起的未完成文件从断点继续，较小的未完成文件从头传。整个目录的结构和逐文件 SHA-256 校验通过后才保存，空目录也会保留。64 MiB 起的单文件上传和下载同样支持断点续传。
- 每项任务可暂停、继续或取消。退出后重新打开仍会保留手动暂停状态。文件夹任务显示已完成文件数和当前文件名。在「设置 → 文件传输」可开启「重连后自动继续」，仅恢复同一台手机上因断线中断的任务。
- 文件列表一次读取整个目录。目录内含符号链接或特殊文件时会提示无法传输。
- 如果上传时手机断开且无法清理，界面会提示需要检查的临时文件路径。
- ADB 访问范围由手机权限决定，不提供 root 或读取其他应用私有数据的能力。
- 大图库吞吐和不同厂商的存储访问范围有待专项测试。

本次构建及真机测试范围见[验证记录](docs/VALIDATION.md)。
