# Poker

Poker 是一款使用 SwiftUI 和 SwiftNIO 开发的 HTTP/HTTPS 抓包与调试工具，支持 macOS 桌面端及 iOS 工程。

## 功能

- 捕获并按域名展示 HTTP/HTTPS 请求
- 查看请求头、请求体、响应头和响应体
- 搜索 URL、HTTP 方法和状态码
- HTTPS MITM 解密及本地 CA 证书安装
- 使用正则表达式自动重写 URL、请求头、响应头和响应体
- 交互式拦截并修改请求参数或响应数据
- 按指定域名限制拦截范围
- 自定义上传、下载速度，模拟弱网环境
- 多选日志并导出 Markdown
- 批量导出图片响应
- 右键复制请求为 cURL

## 环境要求

- macOS 14 或更高版本
- Xcode
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 构建

```bash
git clone <repository-url>
cd Poker
xcodegen generate
open Poker.xcodeproj
```

在 Xcode 中选择 `PokerDesktop` Scheme 后运行。

也可以使用 Swift Package Manager：

```bash
swift build
swift test
swift run PokerDesktop
```

## 使用

1. 启动 PokerDesktop，确认代理端口，默认端口为 `8888`。
2. 点击“启动”开启代理。
3. 将测试设备与 Mac 连接到同一局域网。
4. 在设备网络设置中，将 HTTP 代理设为 Mac 的局域网 IP 和 Poker 端口。
5. 如需抓取 HTTPS，请安装并完全信任 Poker Local CA。
6. 打开目标应用或网页，流量会显示在 Poker 中。

### 请求与响应拦截

工具栏提供独立的“请求拦截”和“响应拦截”开关。开启后，可修改：

- 请求方法、URL、Query 参数、请求头和文本请求体
- 响应状态码、响应头和文本响应体

修改完成后可应用并放行，也可原样放行。关闭拦截开关会自动放行对应阶段的全部待处理流量。通过“拦截范围”可指定域名；留空时匹配全部域名。

### 弱网模式

点击工具栏中的“弱网”按钮，可分别设置上传和下载速度，单位为 `KB/s`。当前弱网模式仅模拟带宽限制，不包含固定延迟或丢包。

### 导出

- 勾选多条日志后可导出为一个 Markdown 文件。
- 如果所选日志全部为图片，可选择批量保存图片或导出 URL 日志。
- 图片日志也可单独导出原始响应数据。

## 测试

```bash
swift test
```

HTTPS 网络集成测试默认跳过，可通过以下命令启用：

```bash
POKER_RUN_NETWORK_TESTS=1 swift test
```

## 安全说明

仅在你拥有或获准测试的设备和网络中使用本工具。抓包完成后，请关闭设备代理并删除不再需要的根证书。使用证书固定（Certificate Pinning）的应用可能无法被解密。
# Poker

Poker 是面向 macOS 与 iOS 的网络请求抓包客户端原型，使用 Swift、SwiftUI、
SwiftNIO 和 NIOSSL 构建。

## 当前能力

- macOS HTTP/1.1 正向代理，默认监听 `0.0.0.0:8888`
- 请求列表、URL 搜索、请求/响应 Header 与 Body 查看
- HTTPS MITM 解密、动态域名证书签发和 `CONNECT` 隧道记录
- WebSocket Upgrade 识别
- URL、请求头、响应头、响应体正则重写
- HAR 1.2 导出
- iOS 代理地址配置和连通性测试界面
- iOS Packet Tunnel 扩展安全骨架

## 快速开始

### macOS

```bash
swift run PokerDesktop
```

在 Poker 中启动代理，然后将 macOS 的 HTTP/HTTPS 代理设置为
`127.0.0.1:8888`。手机与 Mac 处于同一局域网时，可将 iPhone 当前 Wi-Fi 的手动
代理设置为 `Mac 的局域网 IP:8888`。

### iPhone 安装 HTTPS 证书

1. 启动 Poker 代理，点击工具栏的“安装证书”。
2. 在 iPhone Safari 打开页面显示的 `http://Mac-IP:端口/cert`。
3. 允许下载描述文件，然后前往“设置 → 通用 → VPN 与设备管理”完成安装。
4. 前往“设置 → 通用 → 关于本机 → 证书信任设置”，打开对
   `Poker Local CA` 的完全信任。

根证书和私钥保存在当前用户的
`~/Library/Application Support/Poker/Certificates`。不要复制或分享
`PokerCA.key`，只应在测试设备上信任该 CA，抓包结束后应从设备删除。

### Xcode 工程和 iOS

仓库使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述 Apple 工程：

```bash
brew install xcodegen
xcodegen generate
open Poker.xcodeproj
```

如果 Xcode 提示 `Missing package product`，可复用 SwiftPM 的本地缓存完成解析：

```bash
swift package resolve
xcodebuild -resolvePackageDependencies \
  -project Poker.xcodeproj \
  -clonedSourcePackagesDirPath .build \
  -onlyUsePackageVersionsFromResolvedFile \
  -disablePackageRepositoryCache
```

选择 `PokerMobile` scheme 后设置自己的 Development Team。Network Extension
需要 Apple Developer 签名及 `packet-tunnel-provider` entitlement。

## 验证

```bash
swift test
```

## 当前边界

- 证书固定（certificate pinning）的 App 会拒绝 MITM 证书，Poker 不绕过固定。
- WebSocket 当前仅识别握手，尚未持续转发、逐帧展示或修改消息。
- iOS 本机 VPN 模式尚未接入 tun-to-proxy 转发核心。扩展会明确拒绝启动，避免
  配置半成品隧道后造成设备断网；连接 Mac 代理模式可正常使用。
- 暂不支持 HTTP/2、HTTP/3/QUIC、证书固定绕过以及流式大文件落盘。

这些限制是抓包工具中涉及 TLS 信任、TCP/IP 用户态栈和 Apple 特殊权限的独立工程
阶段，不应通过静默降级来伪装成已支持。
