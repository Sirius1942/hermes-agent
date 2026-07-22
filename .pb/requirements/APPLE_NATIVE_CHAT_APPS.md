# Hermes Apple 双原生 Chat App 需求

**需求 ID：** APPLE-CHAT-001
**状态：** 已接受，DesignLoop 评审中
**来源：** 用户需求纠正
**日期：** 2026-07-15
**产品表面：** macOS App、iOS App

## 用户结果

提供一套 macOS PC App 和一套 iOS 手机 App。两者都有独立原生 UI，面向 Hermes 的聊天、
Session、工具和工作管理场景；Hermes 开源 WebUI 保持不动，不嵌入、不换肤、不作为 App UI。

## 必须满足

- macOS 使用 SwiftUI 原生三栏工作台，不包含 WKWebView Dashboard 宿主。
- iOS 使用 SwiftUI 原生单栏 Chat，连接设置和辅助信息通过 sheet/导航进入。
- macOS 本地模式启动 owned `hermes serve`；远程模式和 iOS 连接 HTTPS/WSS `/api/ws`。
- 两端共享 Hermes backend、Profile、SessionDB、Agent、工具、认证和事件事实源。
- 共享 Swift 协议/状态核心，但 UI、窗口和生命周期按平台分别实现。
- Chat 默认主路径包含 Session、新建/恢复、真实流式、停止、工具活动和审批/澄清/secret。
- 管理能力保留并迁移到高级管理中心，按真实 capability/API 分期开放；没有假按钮。
- 明快、中性、工作导向；最终质量以 TestLoop 双端截图和连续录像为准。

## 明确禁止

- 修改 `web/`、Hermes Dashboard `/chat`、TUI、PTY 或 Electron Desktop 来冒充本需求。
- macOS 运行 `hermes dashboard` 或显示 Dashboard URL/WebView。
- 客户端复制 Agent Loop、SessionDB、Provider、工具 schema 或 prompt cache。
- 自动重发结果未知的 prompt、自动批准、secret 回显或日志/截图泄漏凭据。
- 用 mock、fixture transcript、设计图或静态首屏替代真实聊天验收。

## MVP 验收

1. macOS 本地 owned serve 和远程连接可用；iOS 远程连接可用。
2. 双端真实 `message.start/delta/complete` 和 `session.interrupt` 可见。
3. Mac 与 iPhone 对同一 Session 交叉发送/恢复，SessionDB 历史一致。
4. 工具、approval、clarify、secret 原生交互正确且安全。
5. 断网、后台、认证/provider/进程失败均有可见恢复路径。
6. macOS/iOS 多尺寸、动态文字和辅助功能没有遮挡或布局跳动。
7. TestLoop 提供双端核心路径截图和连续录像，并关联同一次 RPC、DB 和日志。
8. git diff 和进程 argv 证明 Hermes 开源 WebUI 未修改、未加载。

## 非目标

首个 MVP 不包含语音、推送、附件、离线生成、完整管理中心、签名、公证、TestFlight、
App Store 或 Mac App Store。它们不得以占位按钮出现，后续单独设计和验收。

