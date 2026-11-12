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
