# Hermes Chat for iOS MVP

> **当前状态：原生 Chat MVP 实现。** App 默认进入 Chat 工作台骨架；连接、Session、Provider、
> 工具活动和 Prompt 使用原生 Sheet。iOS 不加载 Hermes Dashboard，也不在本机启动 Hermes。

这是 Hermes Chat 产品家族的 iPhone-first 原生客户端。它不在本机启动 Hermes，只通过
HTTPS/WSS 连接 `/api/ws`，并复用 backend 的 Session、Profile、Agent、工具和认证事实源。

macOS 对应产品是全新 `Hermes Chat for macOS`；旧 WKWebView Demo 已独立命名为 `Hermes Admin`，
不属于本 App 的导航、依赖或功能回退。

## 构建和测试

需要 Xcode 26.5、iOS 17 SDK 和一个可用的 iOS Simulator：

```bash
cd apps/ios
xcodegen generate --spec project.yml
xcodebuild -project HermesIOS.xcodeproj \
  -scheme HermesIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test CODE_SIGNING_ALLOWED=NO
```

## MVP 行为

- 默认首屏始终是 Chat；连接设置作为 Sheet，不会替换工作台；
- 会话创建 / 恢复、文本发送、流式事件和停止；
- approval、clarify、secret 使用原生 sheet，默认不批准，secret 不回显；
- token 使用 Keychain，ticket 只在连接内存中存在；
- Provider 未配置显示中文恢复卡、App 内配置和保存待重试；
- 工具活动在 Chat 内显示摘要，点击 Sheet 查看详情和 Diff；
- 断线、后台恢复和认证错误显示为可操作状态，不自动重发结果未知的消息。

附件、完整 Dashboard 原生化、推送、语音、离线生成和发布签名不属于 MVP。
