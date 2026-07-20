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
