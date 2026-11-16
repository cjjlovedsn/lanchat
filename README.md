# LanChat

局域网点对点聊天 / 传文件工具（Windows + macOS + Android）。无服务器：UDP 多播自动发现同网段设备，TCP 直连发送。

**核心特性：离线发件箱** —— 对方不在线时，消息和文件先在本机排队（气泡显示"待送达"），程序常驻托盘，对方一上线自动按序送达并转为"已送达"。

## 功能

- 好友列表：自动发现局域网内运行 LanChat 的设备，显示在线状态 / 平台 / 未读数
- 聊天：文字消息，Enter 发送，本地保留聊天记录
- 文件：点按钮选择或直接拖入聊天窗口发送，接收自动存入下载目录（可改），气泡点击可在文件管理器中定位
- 关闭窗口 = 最小化到托盘常驻（保证离线消息能及时投递）；真正退出用托盘菜单"退出"

## 开发

```
flutter pub get
flutter run -d windows          # 开发调试（-d <android设备id> 同理）
flutter test                    # 单元测试（协议/发件箱）
flutter analyze
```

同机双实例测试（数据目录隔离）：

```
set LANCHAT_INSTANCE=A && flutter run -d windows --dart-define=INSTANCE=A
set LANCHAT_INSTANCE=B && flutter run -d windows --dart-define=INSTANCE=B
```

## 构建

**Windows**（需 VS2022 C++ 工具链）：

Windows 首次运行会弹防火墙提示，**务必勾选"专用网络"和"公用网络"再点允许**。如果当时点了取消，Windows 会生成一条阻止规则，之后收不到任何传入连接（表现为：能看到对方在线，但消息永远"待送达"）。修复方法——管理员 PowerShell 删除阻止规则：

```powershell
Get-NetFirewallApplicationFilter | Where-Object {$_.Program -like '*lanchat.exe'} |
  Get-NetFirewallRule | Where-Object {$_.Action -eq 'Block'} | Remove-NetFirewallRule
```



```
flutter build windows --release
# 产物在 build/windows/x64/runner/Release/，整个目录可拷贝分发
# 或直接使用已打包的 dist/lanchat-win-x64.zip
```

**Android**（需 Android SDK，`flutter doctor --android-licenses` 先接受协议）：

```
flutter build apk --release
# 产物 build/app/outputs/flutter-apk/app-release.apk（通用包，含全部 CPU 架构）
```

手机端说明：
- 手机和电脑必须连**同一个路由器、同一网段**（级联路由的"路由模式"下广播不通，跨网段无法发现）
- 安卓端是轻量版：app 在前台时收发/排队正常，切后台被系统杀掉后离线发件箱不投递（无前台服务）
- 首次安装需允许"安装未知应用"；无需任何网络授权弹窗（已在清单声明并持有 MulticastLock）
- 收到的文件在应用私有目录，点文件卡片直接调系统查看器打开
- 工程限制：多路由器级联（IP 段不同）时无法互发，请把分路由设为 AP/桥接模式

**macOS**（在 Mac 上执行，需 Xcode + Flutter）：

```
flutter build macos --release
# 产物在 build/macos/Build/Products/Release/lanchat.app
```

macOS 首次运行注意：

1. 首次启动会弹防火墙提示"是否允许接受传入连接"→ 点允许
2. macOS 15+ 会弹"允许访问本地网络"→ 点允许；若没弹，去
   系统设置 → 隐私与安全性 → 本地网络，手动勾选 LanChat
3. 未签名 app 可能被 Gatekeeper 拦截：右键 → 打开，或
   `xattr -cr /path/to/lanchat.app`。建议用自己的 Apple ID 在 Xcode 里免费签名后分发

## 在 Windows 本地打测试包

使用与仓库 CI 一致的 Flutter **3.35.6**。Windows 版需要 Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载；Android 版另外需要 JDK 17、Android SDK/NDK，并完成 SDK 许可确认。仅用真机测试时无需安装模拟器。

在 PowerShell 中进入仓库，执行：

```powershell
git pull --ff-only
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build windows --release
flutter build apk --release
```

- Windows 便携版：`build/windows/x64/runner/Release/`，需要保留整个目录，不能只拷贝 exe。
- Android APK：`build/app/outputs/flutter-apk/app-release.apk`。
- Windows 安装版：安装 Inno Setup 6 后，在仓库根目录运行以下命令，产物为 `dist/lanchat-setup.exe`：

```powershell
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" installer/lanchat.iss
```

这些命令只在本机生成测试包，不修改版本号、不创建 tag、不发布 Release。不要为本地测试触发发布工作流。

## 发布（GitHub Actions 自动构建）

推 tag 即自动构建三端产物并发布 GitHub Release（无需任何 token）：

```
git tag v1.0.0
git push origin v1.0.0
```

- Windows runner：analyze + test + 便携版 zip + Inno Setup 安装包（版本号取自 tag）
- Ubuntu runner：安卓 APK
- macOS runner：未签名 .app 压缩包（失败不阻塞发布，也可在 Mac 上自行构建）
- 产物自动挂到对应 tag 的 Release 页

## 协议

- 发现：UDP 多播 `224.0.0.198:38701`，3 秒一次广播 JSON `{proto,id,name,platform,port}`，25 秒无包判离线；同时辅以子网定向广播兜底
- 传输：TCP `38702`，帧格式 `[u32 jsonLen][header JSON][u32 payloadLen][payload]`；每连接先 `hello`，随后若干 `text` / `file` 帧（文件为流式 payload + sha256 校验），逐条 `ack` 确认后才出队，未确认的崩溃后可安全重发（按 msgId 去重）
- 数据目录：Windows `%LOCALAPPDATA%\local.lanchat.lanchat`，macOS `~/Library/Application Support/local.lanchat.lanchat`，Android 应用私有目录（可用 `LANCHAT_INSTANCE` 环境变量隔离，用于同机多开测试）
- 安卓差异：窗口/托盘/拖拽仅桌面端；竖屏手机为单栏布局（列表↔聊天）；UDP 多播需持 MulticastLock（MainActivity 已处理）；点击收到的文件用系统查看器打开（open_filex）

## 聊天与媒体

- 输入框支持多行：Enter 发送，Shift+Enter / Ctrl+Enter 换行；手机也可点击工具栏换行按钮。
- 点击输入框旁的代码按钮切换代码消息，保留缩进和空行；代码气泡支持横向滚动和一键复制原文。
- 普通文字中的 HTTP/HTTPS 和 www 链接可点击，在外部浏览器打开。
- 视频气泡点击后进入应用内播放器，支持进度控制和全屏；无法播放时可切换到系统播放器。不会自动播放聊天列表中的视频。
- 当前协议单文件必须小于 4 GiB；更大的文件请先拆分。文件读取失败会显示提示。
- 传输按消息逐条确认；未确认或校验失败的消息保留在离线发件箱等待重试。
- 视频播放使用 media_kit 原生解码库，因此安装包体积会有所增加。

## 设备显示离线时

点击设备列表顶部的网络图标查看「网络诊断」，可以复制本机地址、发现监听状态、发送连接数及收到的广播数。

发现服务会定期重试失败的套接字，并在网络切换或应用回到前台后重新建立连接。多播和子网广播分别使用独立的发送连接，发送失败不会关闭接收监听。Windows 安装更新后请从托盘退出旧实例再启动新版。

## 外观设置

设备列表顶部的调色盘或「设置 → 外观与主题」可切换晴空蓝、松石绿、暮光紫、暖砂橙四种配色，以及浅色、深色、跟随系统模式。修改即时生效并保存在本机。

## 应用图标

Logo 使用相扣的聊天气泡，表达局域网设备连接与对话。可编辑母版为 `assets/brand/lanchat.svg`；各平台图标均已包含在仓库中，正常构建不需要重新生成。

修改母版后，安装 Python 3 和 Pillow，运行 `python3 tool/generate_brand_assets.py`，会更新 macOS、Windows、Android、托盘及应用内图标。Android 包含自适应图标；macOS 托盘使用随系统明暗变化的单色模板。

## 开机启动与聊天操作

- 桌面端在「设置」和托盘／状态栏右键菜单中提供「开机启动」开关，macOS 应用菜单也有相同入口。默认关闭；开启后，在当前用户登录电脑时启动。macOS 使用当前用户 LaunchAgent，Windows 使用当前用户 Run 项，无需管理员权限。移动应用位置后应重新开启以更新路径。
- 聊天记录区域的空白处右键可选「清空聊天」，确认后仅清除当前会话的本机记录及待发送队列，保留已接收文件；正在发送的内容可能已经送达。
- 输入框支持粘贴文件及图片：Mac 用 Cmd+V，Windows 用 Ctrl+V，也可在输入框右键选「粘贴」。附件直接发送，已有文字草稿会保留；纯文字按原样插入输入框。暂不支持粘贴文件夹。Android 支持系统剪贴板 URI 及输入法图片插入，具体能力取决于来源应用和输入法。

## 应用内更新

- 正式版默认启动后检查 GitHub 最新正式 Release，随后每 6 小时检查一次；不会自动下载。设置中可以关闭自动检查，或手动点击「检查更新」，桌面托盘菜单也有入口。
- 有新版时提示版本和更新说明。点击「下载并安装」后才下载对应平台安装包，显示进度并支持取消；下载完成后核对大小及 GitHub 的 SHA256。校验失败不会安装，也不会运行不完整的下载。
- Windows 启动安装程序，保留当前安装目录，并退出旧版；系统可能需要管理员确认。
- macOS 验证 DMG 内的应用标识、版本和代码签名，在当前应用目录旁暂存新版，退出后替换并重启；无法替换或启动时尝试恢复旧版。应用目录需要可写，DMG 中直接运行的应用需先移到应用程序目录。保留一份旧应用作为备份，在下一次更新准备时清理。
- Android 下载后检查包名、版本号及签名，再进入系统安装界面；首次可能需要允许 LanChat 安装应用，授权后返回再点安装。文件传输进行中会延后启动安装。
- 更新只替换应用文件，聊天数据仍存放在原数据目录中。局域网聊天不依赖 GitHub；联网失败不会阻断聊天和传文件。
- 当前仓库仅发布 x64 Windows 安装包和通用 Android APK；Mac 更新需要发布 `lanchat-macos.dmg`。缺少安装包或 SHA256 时会提示，不能应用内安装。

## Android 签名与覆盖安装

正式 APK 必须一直使用同一个发布密钥。仓库已有固定密钥及配置；**不要重新生成或替换密钥**。Release 构建缺少配置、缺少密钥或证书指纹变化时会失败，不再退回 debug 签名。固定证书指纹记录在 `android/release-certificate.sha256`，CI 构建后还会用 `apksigner` 验证实际 APK 的签名。

Windows 本机构建正式 APK 后，也可运行 `python scripts/verify-android-signature.py` 核对；需要 Android SDK build-tools。调试版使用独立的 `.debug` 应用 ID，避免与正式版相互覆盖。

若手机上已有应用使用另一个签名，Android 无法直接覆盖安装。需要先保留重要的记录和文件，再卸载旧版并安装使用固定签名的正式 APK；卸载可能清除应用私有数据。应用内更新发现签名不符会先提示，不会自动卸载。无法仅通过新 APK 修复已经存在的不同签名安装。
